import AIKit
import Foundation

/// One text completion: a system prompt, a user prompt, one answer. No
/// tools, no multi-turn, no images — everything TheGit asks a model for
/// fits in this shape.
struct AIRequest {
    var system: String
    var user: String
    /// nil leaves the cap to the provider. Anthropic requires one on the
    /// wire and AIKit fills in the model's own maximum there.
    var maxOutputTokens: Int?

    init(system: String, user: String, maxOutputTokens: Int? = nil) {
        self.system = system
        self.user = user
        self.maxOutputTokens = maxOutputTokens
    }
}

/// Where to send it: a provider out of AIKit's catalog, its base URL
/// (possibly overridden by the user), the key, and the chosen model.
struct AIEndpoint {
    var provider: ProviderInfo
    var baseURL: URL
    var apiKey: String
    var model: String
}

struct AIError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// The seam between TheGit and AIKit.
///
/// AIKit normalizes fifty providers onto one event stream; TheGit only ever
/// wants the text out of it. This narrows that stream back down to `String`
/// deltas and turns AIKit's errors into the sentences the settings pane and
/// the commit box show.
enum AIGateway {

    /// Text deltas as they arrive. Cancelling the consuming task cancels
    /// the request — that's what the stop button is wired to.
    static func stream(_ request: AIRequest, endpoint: AIEndpoint) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let work = Task {
                do {
                    let client = makeClient(endpoint)
                    var produced = false
                    for try await part in try client.stream(callOptions(request, endpoint)) {
                        try Task.checkCancellation()
                        switch part {
                        case .textDelta(_, let delta, _):
                            guard !delta.isEmpty else { continue }
                            produced = true
                            continuation.yield(delta)
                        case .error(let error):
                            // A failure that arrives mid-stream has already
                            // cost the user an answer; keeping what landed
                            // beats replacing it with an alert. Nothing at
                            // all, though, is a failure worth reporting.
                            guard produced else { throw AIError(message: error.message) }
                            continuation.finish()
                            return
                        default:
                            continue
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch let error as URLError where error.code == .cancelled {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: friendly(error, endpoint: endpoint))
                }
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }

    /// Everything in one string. Used by the settings window's connection
    /// test, where there is nothing to stream into.
    static func complete(_ request: AIRequest, endpoint: AIEndpoint) async throws -> String {
        do {
            return try await makeClient(endpoint).generate(callOptions(request, endpoint)).text
        } catch {
            throw friendly(error, endpoint: endpoint)
        }
    }

    /// Ask the endpoint what it can run. The catalog can't know for Ollama,
    /// LM Studio or the gateways, and it goes stale for everyone else.
    static func models(endpoint: AIEndpoint) async throws -> [ModelInfo] {
        do {
            return try await makeClient(endpoint).models().sorted { $0.id < $1.id }
        } catch {
            throw friendly(error, endpoint: endpoint)
        }
    }

    // MARK: - Plumbing

    private static func makeClient(_ endpoint: AIEndpoint) -> AIClient {
        AIClient(
            provider: endpoint.provider,
            configuration: .init(
                // An empty key is a local endpoint, not a blank credential:
                // sending `Authorization: Bearer ` makes Ollama look broken.
                authorization: endpoint.apiKey.isEmpty ? .none : .apiKey(endpoint.apiKey),
                baseURL: endpoint.baseURL
            )
        )
    }

    static func callOptions(_ request: AIRequest, _ endpoint: AIEndpoint) -> CallOptions {
        CallOptions(
            model: endpoint.model,
            prompt: [.system(request.system), .user(request.user)],
            maxOutputTokens: request.maxOutputTokens,
            // Writing a commit message is not a reasoning problem, and on the
            // models that think by default the tokens are pure latency and
            // cost. AIKit resolves this against what the model can actually
            // do, so a model that cannot stop thinking is turned down instead.
            thinking: .off
        )
    }

    /// AIKit reports failures faithfully — a status and the provider's own
    /// body. Both need saying in one line that names what to go fix.
    static func friendly(_ error: Error, endpoint: AIEndpoint) -> Error {
        let name = endpoint.provider.displayName

        if let client = error as? AIClientError {
            switch client.kind {
            case .http(let status, let body):
                return statusError(status, body: AIErrorBody.message(Data(body.utf8)), endpoint: endpoint)
            case .missingBaseURL:
                return AIError(message: "Set a Base URL for \(name) in Settings (⌘,)")
            case .unknownProvider, .unsupportedProtocol:
                return AIError(message: client.description)
            }
        }

        guard let url = error as? URLError else { return error }
        switch url.code {
        case .timedOut:
            return AIError(message: "The request timed out.")
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            return AIError(message: "Can't reach the endpoint — check the Base URL, and that a local server is running.")
        case .notConnectedToInternet:
            return AIError(message: "No network connection.")
        case .secureConnectionFailed, .serverCertificateUntrusted:
            return AIError(message: "TLS handshake failed for this endpoint.")
        default:
            return AIError(message: url.localizedDescription)
        }
    }

    static func statusError(_ code: Int, body: String?, endpoint: AIEndpoint) -> AIError {
        let name = endpoint.provider.displayName
        let detail = body.map { ": \($0)" } ?? ""
        switch code {
        case 401, 403:
            return AIError(message: "\(name) rejected the API key\(detail)")
        case 404:
            return AIError(message: "\(name) has no \(endpoint.model) at \(endpoint.baseURL.absoluteString) — check the model and Base URL\(detail)")
        case 429:
            return AIError(message: "\(name) is rate limiting this key\(detail)")
        case 500...599:
            return AIError(message: "\(name) failed (HTTP \(code))\(detail)")
        default:
            return AIError(message: "\(name) returned HTTP \(code)\(detail)")
        }
    }
}

/// Providers report failures as `{"error": {"message": …}}`, near enough
/// universally, so one reader covers them. Falls back to the raw body,
/// truncated — an unparsed wall of HTML from a misconfigured proxy helps
/// nobody.
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
