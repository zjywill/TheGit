import Foundation

/// One text completion: a system prompt, a user prompt, one answer. No
/// tools, no multi-turn, no images — everything TheGit asks a model for
/// fits in this shape.
struct AIRequest {
    var system: String
    var user: String
    var maxOutputTokens: Int = 1024
}

/// Where to send it: a provider, its base URL (possibly overridden by the
/// user), the key, and the chosen model.
struct AIEndpoint {
    var provider: AIProvider
    var baseURL: URL
    var apiKey: String
    var model: String
    /// From the catalog, when it knows this model. nil for one the endpoint
    /// reported at runtime — in which case we send no thinking knobs at
    /// all, since guessing one a server doesn't know is a 400.
    var noThink: AIThinkingOff?
}

enum AIStreamEvent: Equatable {
    case delta(String)
    case done
}

struct AIError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// A single wire protocol. Request building and response parsing are pure
/// functions on purpose — the tests drive them with canned SSE frames and
/// never open a socket.
protocol AIWireAdapter {
    func chatURL(_ endpoint: AIEndpoint) -> URL
    func headers(_ endpoint: AIEndpoint) -> [String: String]
    func body(_ request: AIRequest, _ endpoint: AIEndpoint) throws -> Data
    /// One SSE `data:` payload. nil for frames that carry no text.
    func event(from payload: String) -> AIStreamEvent?

    func modelsURL(_ endpoint: AIEndpoint) -> URL
    func models(from data: Data) throws -> [AIModel]
}

extension AIAdapterKind {
    var wire: AIWireAdapter {
        switch self {
        case .openai: return OpenAIWire()
        case .anthropic: return AnthropicWire()
        case .gemini: return GeminiWire()
        }
    }
}

// MARK: - Shared helpers

extension URL {
    /// Appends an API path, skipping a leading segment the base already
    /// ends with. MiniMax's Anthropic endpoint is `…/anthropic/v1`, and
    /// `v1/messages` on top of that would be `…/v1/v1/messages`.
    func appendingAPIPath(_ path: String) -> URL {
        var segments = path.split(separator: "/").map(String.init)
        if let first = segments.first, absoluteString.hasSuffix("/" + first) {
            segments.removeFirst()
        }
        return segments.reduce(self) { $0.appendingPathComponent($1) }
    }
}

/// All three providers report failures as `{"error": {"message": …}}`, so
/// one reader covers them. Falls back to the raw body, truncated — an
/// unparsed wall of HTML from a misconfigured proxy helps nobody.
enum AIErrorBody {
    static func message(_ data: Data) -> String? {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = object["error"] as? [String: Any],
               let message = error["message"] as? String { return message }
            if let message = object["error"] as? String { return message }
            if let message = object["message"] as? String { return message }
        }
        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { return nil }
        return text.count > 300 ? String(text.prefix(300)) + "…" : text
    }
}

private func encode(_ object: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: object)
}

private func json(_ payload: String) -> [String: Any]? {
    guard let data = payload.data(using: .utf8) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}

// MARK: - OpenAI

/// `/chat/completions`, which is what 41 of the 49 catalog entries speak.
struct OpenAIWire: AIWireAdapter {
    func chatURL(_ endpoint: AIEndpoint) -> URL {
        endpoint.baseURL.appendingAPIPath("chat/completions")
    }

    func headers(_ endpoint: AIEndpoint) -> [String: String] {
        var headers = ["Content-Type": "application/json"]
        if !endpoint.apiKey.isEmpty {
            let auth = endpoint.provider.auth
            headers[auth.header] = auth.prefix + endpoint.apiKey
        }
        return headers
    }

    func body(_ request: AIRequest, _ endpoint: AIEndpoint) throws -> Data {
        // Deliberately minimal: gpt-5 and the o-series reject `temperature`
        // outright and want `max_completion_tokens` instead of `max_tokens`,
        // so sending neither is the one body every model accepts.
        var body: [String: Any] = [
            "model": endpoint.model,
            "stream": true,
            "messages": [
                ["role": "system", "content": request.system],
                ["role": "user", "content": request.user],
            ],
        ]

        // Only for models the catalog says reason by default, and only in
        // the form that model's provider documents.
        if let noThink = endpoint.noThink {
            switch noThink.off {
            case "thinking_type": body["thinking"] = ["type": "disabled"]
            case "enable_thinking": body["enable_thinking"] = false
            case "thinking_budget": body["thinking_budget"] = 0
            default:
                if let effort = noThink.effort { body["reasoning_effort"] = effort }
            }
        }

        return try encode(body)
    }

    func event(from payload: String) -> AIStreamEvent? {
        if payload == "[DONE]" { return .done }
        guard let object = json(payload) else { return nil }
        guard let choices = object["choices"] as? [[String: Any]],
              let first = choices.first else { return nil }
        if let delta = first["delta"] as? [String: Any],
           let content = delta["content"] as? String, !content.isEmpty {
            return .delta(content)
        }
        if first["finish_reason"] is String { return .done }
        return nil
    }

    func modelsURL(_ endpoint: AIEndpoint) -> URL {
        endpoint.baseURL.appendingAPIPath("models")
    }

    func models(from data: Data) throws -> [AIModel] {
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let list = object?["data"] as? [[String: Any]] else {
            throw AIError(message: AIErrorBody.message(data) ?? "Unexpected model list.")
        }
        return list.compactMap { entry in
            guard let id = entry["id"] as? String else { return nil }
            return AIModel(id: id, name: id)
        }
    }
}

// MARK: - Anthropic

struct AnthropicWire: AIWireAdapter {
    func chatURL(_ endpoint: AIEndpoint) -> URL {
        endpoint.baseURL.appendingAPIPath("v1/messages")
    }

    func headers(_ endpoint: AIEndpoint) -> [String: String] {
        var headers = [
            "Content-Type": "application/json",
            "anthropic-version": "2023-06-01",
        ]
        if !endpoint.apiKey.isEmpty {
            let auth = endpoint.provider.auth
            headers[auth.header] = auth.prefix + endpoint.apiKey
        }
        return headers
    }

    func body(_ request: AIRequest, _ endpoint: AIEndpoint) throws -> Data {
        // Nothing to switch off: extended thinking is opt-in on this API,
        // and a body without a `thinking` block never gets any.
        // max_tokens is required here, unlike on the OpenAI side.
        try encode([
            "model": endpoint.model,
            "max_tokens": request.maxOutputTokens,
            "stream": true,
            "system": request.system,
            "messages": [["role": "user", "content": request.user]],
        ])
    }

    func event(from payload: String) -> AIStreamEvent? {
        guard let object = json(payload) else { return nil }
        switch object["type"] as? String {
        case "content_block_delta":
            guard let delta = object["delta"] as? [String: Any],
                  let text = delta["text"] as? String, !text.isEmpty else { return nil }
            return .delta(text)
        case "message_stop":
            return .done
        default:
            return nil
        }
    }

    func modelsURL(_ endpoint: AIEndpoint) -> URL {
        endpoint.baseURL.appendingAPIPath("v1/models")
    }

    func models(from data: Data) throws -> [AIModel] {
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let list = object?["data"] as? [[String: Any]] else {
            throw AIError(message: AIErrorBody.message(data) ?? "Unexpected model list.")
        }
        return list.compactMap { entry in
            guard let id = entry["id"] as? String else { return nil }
            return AIModel(id: id, name: entry["display_name"] as? String ?? id)
        }
    }
}

// MARK: - Gemini

struct GeminiWire: AIWireAdapter {
    func chatURL(_ endpoint: AIEndpoint) -> URL {
        let model = endpoint.model
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? endpoint.model
        // Built as a string: the action is a `:` suffix on the last path
        // component, which appendingPathComponent would escape.
        let base = endpoint.baseURL.absoluteString
        return URL(string: "\(base)/models/\(model):streamGenerateContent?alt=sse")
            ?? endpoint.baseURL
    }

    func headers(_ endpoint: AIEndpoint) -> [String: String] {
        var headers = ["Content-Type": "application/json"]
        if !endpoint.apiKey.isEmpty {
            let auth = endpoint.provider.auth
            headers[auth.header] = auth.prefix + endpoint.apiKey
        }
        return headers
    }

    func body(_ request: AIRequest, _ endpoint: AIEndpoint) throws -> Data {
        var config: [String: Any] = ["maxOutputTokens": request.maxOutputTokens]
        // A budget of 0 is Gemini's off switch, but only the models that
        // offer a minimal tier accept it — the rest clamp to their floor
        // and answer 400. Nothing sent for those.
        if let effort = endpoint.noThink?.effort, effort == "none" || effort == "minimal" {
            config["thinkingConfig"] = ["thinkingBudget": 0]
        }
        return try encode([
            "systemInstruction": ["parts": [["text": request.system]]],
            "contents": [["role": "user", "parts": [["text": request.user]]]],
            "generationConfig": config,
        ])
    }

    func event(from payload: String) -> AIStreamEvent? {
        guard let object = json(payload),
              let candidates = object["candidates"] as? [[String: Any]],
              let first = candidates.first else { return nil }
        if let content = first["content"] as? [String: Any],
           let parts = content["parts"] as? [[String: Any]] {
            let text = parts.compactMap { $0["text"] as? String }.joined()
            if !text.isEmpty { return .delta(text) }
        }
        // Gemini has no terminating frame; the stream just ends. A finish
        // reason is the closest thing, and only worth acting on when it
        // arrives without text.
        if first["finishReason"] is String { return .done }
        return nil
    }

    func modelsURL(_ endpoint: AIEndpoint) -> URL {
        endpoint.baseURL.appendingAPIPath("models")
    }

    func models(from data: Data) throws -> [AIModel] {
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let list = object?["models"] as? [[String: Any]] else {
            throw AIError(message: AIErrorBody.message(data) ?? "Unexpected model list.")
        }
        return list.compactMap { entry in
            // Names come back fully qualified: "models/gemini-3-flash".
            guard let name = entry["name"] as? String else { return nil }
            let id = name.hasPrefix("models/") ? String(name.dropFirst(7)) : name
            return AIModel(id: id, name: entry["displayName"] as? String ?? id)
        }
    }
}
