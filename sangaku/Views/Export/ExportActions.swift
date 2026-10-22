import SwiftUI

/// What a screen or a menu asks of export, through the window's `exportActions`. Exports name roles, never models, so
/// nothing here waits while blind mode is on.
nonisolated enum ExportIntent: Hashable, Sendable {
    case open(ExportKind)
    case stop(problem: UUID)
    case showReport
}

/// An export sheet, open in one window.
nonisolated enum ExportSheet: Hashable, Sendable, Identifiable {
    /// What an export of this kind would write, with the folder to choose and the Export button.
    case plan(ExportKind)
    /// How the last export of the problem ended.
    case report

    var id: Self { self }
}

/// The window's handler of export intents.
typealias ExportActions = PresentedAction<ExportIntent>

/// The one handler of export intents, from the card and the File menu alike.
enum ExportIntentHandler {
    static func perform(_ intent: ExportIntent, window: WindowState, export: ExportService?) {
        switch intent {
        case .open(let kind): window.exportSheet = .plan(kind)
        case .stop(let problem): export?.stop(problem: problem)
        case .showReport: window.exportSheet = .report
        }
    }
}

/// Presents the window's export sheets and handles export intents.
struct ExportSheetHost: ViewModifier {
    let window: WindowState

    @Environment(\.exportService) private var export
    @State private var presenter = UUID()

    func body(content: Content) -> some View {
        content
            .environment(\.exportActions, ExportActions(presenter: presenter) { [window, export] intent in
                ExportIntentHandler.perform(intent, window: window, export: export)
            })
            .sheet(item: Binding(get: { window.exportSheet }, set: { window.exportSheet = $0 })) { sheet in
                if let id = window.selectedProblemID {
                    ProblemScope(id: id) { problem in
                        switch sheet {
                        case .plan(let kind): ExportPlanSheet(problem: problem, kind: kind)
                        case .report: ExportReportSheet(problem: problem, outcome: export?.outcomes[problem.stableID])
                        }
                    }
                }
            }
    }
}

extension View {
    /// The window's export sheets and intents (`ExportSheetHost`).
    func exportSheets(window: WindowState) -> some View {
        modifier(ExportSheetHost(window: window))
    }
}
