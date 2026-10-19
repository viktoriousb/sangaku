import Foundation
import Testing
@testable import sangaku

@Test func testHostLoads() {
    #expect(Bundle.main.bundleIdentifier == "local.sangaku")
}
