import Foundation

/// Stable provider identifiers, as stored in `Problem.allowedProviderIDs` and `ModelSlot.providerID`.
nonisolated enum ProviderID {
    static let anthropic = "anthropic"
}

/// One LLM provider. `stream` returns at once; the request runs off the main actor and its events arrive in
/// order. Cancelling the consuming task cancels the request.
nonisolated protocol ModelProvider: Sendable {
    var id: String { get }
    var displayName: String { get }
    func stream(_ request: ProviderRequest) -> AsyncThrowingStream<ProviderEvent, any Error>
}

/// A provider as the policy UI lists it.
nonisolated struct ProviderDescriptor: Hashable, Identifiable, Sendable {
    var id: String
    var displayName: String
}

/// The app's providers, keyed by ID.
nonisolated struct ProviderRegistry: Sendable {
    private let providers: [String: any ModelProvider]
    /// In the order given, for the policy UI.
    let descriptors: [ProviderDescriptor]

    init(_ providers: [any ModelProvider]) {
        self.providers = Dictionary(providers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        descriptors = providers.map { ProviderDescriptor(id: $0.id, displayName: $0.displayName) }
    }

    /// The provider for a request. A request is only ever handed to the provider it was built for.
    func provider(for request: ProviderRequest) -> (any ModelProvider)? {
        providers[request.providerID]
    }

    func displayName(for providerID: String) -> String {
        descriptors.first { $0.id == providerID }?.displayName ?? providerID
    }
}
