import Foundation

/// The whole HTTP layer. Swift has no equivalent of the TypeScript AI SDK,
/// and a one-shot text completion doesn't need one: URLSession streams SSE
/// natively, and `AIWireAdapter` already knows the three request shapes.
enum AIClient {
    /// Text deltas as they arrive. Cancelling the consuming task cancels
    /// the request — that's what the stop button is wired to.
    static func stream(_ request: AIRequest, endpoint: AIEndpoint) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let work = Task {
                do {
                    let adapter = endpoint.provider.adapter.wire
                    let urlRequest = try makeRequest(request, endpoint: endpoint, adapter: adapter)
                    let (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)
                    try await checkStatus(response, bytes: bytes, endpoint: endpoint)

                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard let payload = ssePayload(line) else { continue }
                        switch adapter.event(from: payload) {
                        case .delta(let text):
                            continuation.yield(text)
                        case .done:
                            continuation.finish()
                            return
                        case nil:
                            continue
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch let error as URLError where error.code == .cancelled {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: friendly(error))
                }
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }

    /// Everything in one string. Used by the settings window's connection
    /// test, where there is nothing to stream into.
    static func complete(_ request: AIRequest, endpoint: AIEndpoint) async throws -> String {
        var text = ""
        for try await delta in stream(request, endpoint: endpoint) { text += delta }
        return text
    }

    /// Ask the endpoint what it can run. The catalog can't know for Ollama,
    /// LM Studio or the gateways, and it goes stale for everyone else.
    static func models(endpoint: AIEndpoint) async throws -> [AIModel] {
        let adapter = endpoint.provider.adapter.wire
        var request = URLRequest(url: adapter.modelsURL(endpoint))
        request.timeoutInterval = 20
        for (field, value) in adapter.headers(endpoint) {
            request.setValue(value, forHTTPHeaderField: field)
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw statusError(http.statusCode, body: AIErrorBody.message(data), endpoint: endpoint)
            }
            return try adapter.models(from: data).sorted { $0.id < $1.id }
        } catch let error as AIError {
            throw error
        } catch {
            throw friendly(error)
        }
    }

    // MARK: - Plumbing

    private static func makeRequest(
        _ request: AIRequest,
        endpoint: AIEndpoint,
        adapter: AIWireAdapter
    ) throws -> URLRequest {
        var urlRequest = URLRequest(url: adapter.chatURL(endpoint))
        urlRequest.httpMethod = "POST"
        // Applies to the first byte, not the whole stream.
        urlRequest.timeoutInterval = 60
        urlRequest.httpBody = try adapter.body(request, endpoint)
        for (field, value) in adapter.headers(endpoint) {
            urlRequest.setValue(value, forHTTPHeaderField: field)
        }
        return urlRequest
    }

    /// A non-2xx arrives with its explanation in the body, which for a
    /// streaming request means draining bytes we were never going to parse.
    private static func checkStatus(
        _ response: URLResponse,
        bytes: URLSession.AsyncBytes,
        endpoint: AIEndpoint
    ) async throws {
        guard let http = response as? HTTPURLResponse,
              !(200..<300).contains(http.statusCode) else { return }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > 8192 { break }
        }
        throw statusError(http.statusCode, body: AIErrorBody.message(data), endpoint: endpoint)
    }

    private static func statusError(_ code: Int, body: String?, endpoint: AIEndpoint) -> AIError {
        let detail = body.map { ": \($0)" } ?? ""
        switch code {
        case 401, 403:
            return AIError(message: "\(endpoint.provider.name) rejected the API key\(detail)")
        case 404:
            return AIError(message: "\(endpoint.provider.name) has no \(endpoint.model) at \(endpoint.baseURL.absoluteString) — check the model and Base URL\(detail)")
        case 429:
            return AIError(message: "\(endpoint.provider.name) is rate limiting this key\(detail)")
        case 500...599:
            return AIError(message: "\(endpoint.provider.name) failed (HTTP \(code))\(detail)")
        default:
            return AIError(message: "\(endpoint.provider.name) returned HTTP \(code)\(detail)")
        }
    }

    private static func friendly(_ error: Error) -> Error {
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

    /// The payload of one SSE line, or nil for comments, event names and
    /// the blank lines between frames.
    static func ssePayload(_ line: String) -> String? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        return payload.isEmpty ? nil : payload
    }
}
