import SwiftData
import SwiftUI

/// Looks up one problem by stable ID and hands it to its content, with that problem's macros in the
/// environment so every `MathText` below renders with them.
struct ProblemScope<Content: View>: View {
    @Query private var matches: [Problem]
    @Environment(\.problemManager) private var problems
    private let content: (Problem) -> Content

    init(id: UUID, @ViewBuilder content: @escaping (Problem) -> Content) {
        _matches = Query(filter: #Predicate<Problem> { $0.stableID == id })
        self.content = content
    }

    var body: some View {
        if let problem = matches.first {
            content(problem)
                .environment(\.mathContext, problems?.mathContext(for: problem) ?? MathContext())
        } else {
            ContentUnavailableView("Problem not found", systemImage: "questionmark.square.dashed")
        }
    }
}
