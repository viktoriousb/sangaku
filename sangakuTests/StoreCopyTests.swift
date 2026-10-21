import Foundation
import SwiftData
import Testing
@testable import sangaku

/// Opens a copy of a real store with the current schema, to show a schema change needs no reset. Runs only when a copy
/// is named: `TEST_RUNNER_SANGAKU_STORE_COPY=<path to a copied sangaku.store>` passed to the test run. Never the store
/// itself: SwiftData may rewrite what it opens.
@Suite("A copy of a real store opens")
struct StoreCopyTests {
    private nonisolated static let copy = ProcessInfo.processInfo.environment["SANGAKU_STORE_COPY"]

    @Test(.enabled(if: copy != nil))
    func opens() throws {
        let url = URL(fileURLWithPath: try #require(Self.copy))
        #expect(!url.path.contains("/Library/Application Support/"), "a copy, never the store itself")
        let container = try ModelContainerFactory.make(.disk(url))
        let context = container.mainContext
        let problems = try context.fetchCount(FetchDescriptor<Problem>())
        let results = try context.fetch(FetchDescriptor<LeanResult>())
        #expect(problems >= 0)
        // A result stored before the axiom check was recorded can never count.
        #expect(results.allSatisfy { $0.axiomCheck == .notRun || !$0.checkedDigest.isEmpty })
    }
}
