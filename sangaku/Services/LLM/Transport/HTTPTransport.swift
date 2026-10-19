import Foundation

/// An HTTP response whose body arrives as it is sent.
nonisolated struct HTTPStreamResponse: Sendable {
    var status: Int
    /// Header names lowercased.
    var headers: [String: String]
    var chunks: AsyncThrowingStream<Data, any Error>
}

/// Opens streaming HTTP requests. The one place the app reaches the network, so tests and the fixture can
/// replace it.
nonisolated protocol HTTPTransport: Sendable {
    @concurrent func open(_ request: URLRequest) async throws -> HTTPStreamResponse
}

/// The real network, through a URLSession with no cache and no cookies.
nonisolated struct URLSessionTransport: HTTPTransport {
    let session: URLSession

    static func standard() -> URLSessionTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        // Long thinking sends pings, so a quiet period this long means the connection is gone.
        configuration.timeoutIntervalForRequest = 300
        configuration.timeoutIntervalForResource = 4 * 60 * 60
        return URLSessionTransport(session: URLSession(configuration: configuration))
    }

    @concurrent func open(_ request: URLRequest) async throws -> HTTPStreamResponse {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.transport("The server's response was not HTTP.")
        }
        var headers: [String: String] = [:]
        for (name, value) in http.allHeaderFields {
            if let name = name as? String, let value = value as? String { headers[name.lowercased()] = value }
        }
        let chunks = AsyncThrowingStream<Data, any Error> { continuation in
            let task = Task {
                var buffer = Data()
                do {
                    // Hand on whole lines as they complete, so events reach the parser without delay.
                    for try await byte in bytes {
                        buffer.append(byte)
                        if byte == UInt8(ascii: "\n") || buffer.count >= 16_384 {
                            continuation.yield(buffer)
                            buffer.removeAll(keepingCapacity: true)
                        }
                    }
                    if !buffer.isEmpty { continuation.yield(buffer) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return HTTPStreamResponse(status: http.statusCode, headers: headers, chunks: chunks)
    }
}

/// Refuses every request: used where the app must never reach the network (tests, previews, the fixture).
nonisolated struct UnavailableTransport: HTTPTransport {
    @concurrent func open(_ request: URLRequest) async throws -> HTTPStreamResponse {
        throw ProviderError.transport("Network requests are turned off in this copy of the app (tests, previews or the fixture).")
    }
}
