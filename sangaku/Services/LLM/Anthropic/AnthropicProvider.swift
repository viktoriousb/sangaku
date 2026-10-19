import Foundation

/// Anthropic's Messages API, streamed. The key is read from the secret store inside the request, off the main
/// actor, and goes only into the request header.
nonisolated struct AnthropicProvider: ModelProvider {
    static let keyAccount = SecretAccount.apiKey(for: ProviderID.anthropic)

    let id = ProviderID.anthropic
    let displayName = "Anthropic"
    let transport: any HTTPTransport
    let secrets: any SecretStore

    func stream(_ request: ProviderRequest) -> AsyncThrowingStream<ProviderEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [transport, secrets] in
                await Self.produce(request, transport: transport, secrets: secrets, into: continuation)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    @concurrent
    private static func produce(_ request: ProviderRequest, transport: any HTTPTransport, secrets: any SecretStore,
                                into continuation: AsyncThrowingStream<ProviderEvent, any Error>.Continuation) async {
        do {
            let key: String?
            do {
                key = try await secrets.read(keyAccount)
            } catch {
                throw ProviderError.keychain((error as? SecretStoreError)?.message ?? error.localizedDescription)
            }
            guard let key, !key.isEmpty else { throw ProviderError.missingKey }
            let response = try await transport.open(AnthropicWire.urlRequest(request, apiKey: key))
            guard response.status == 200 else {
                var body = Data()
                for try await chunk in response.chunks {
                    body.append(chunk)
                    if body.count > 65_536 { break }
                }
                throw AnthropicWire.error(status: response.status, headers: response.headers, body: body)
            }
            var parser = SSEParser()
            var decoder = AnthropicEventDecoder()
            for try await chunk in response.chunks {
                for event in parser.feed(chunk) {
                    for providerEvent in try decoder.decode(event) { continuation.yield(providerEvent) }
                }
                if decoder.isFinished { break }
            }
            // A last line cut off mid-event cannot be read; if the stop reason already arrived the reply is
            // still finished, which `decoder.finish()` decides.
            for event in parser.finish() {
                guard let events = try? decoder.decode(event) else { break }
                for providerEvent in events { continuation.yield(providerEvent) }
            }
            for providerEvent in try decoder.finish() { continuation.yield(providerEvent) }
            continuation.finish()
        } catch let error as ProviderError {
            continuation.finish(throwing: error)
        } catch {
            if Task.isCancelled || error is CancellationError {
                continuation.finish(throwing: CancellationError())
            } else {
                continuation.finish(throwing: ProviderError.transport(error.localizedDescription))
            }
        }
    }
}
