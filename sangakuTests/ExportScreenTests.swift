import AppKit
import Foundation
import SwiftUI
import Testing
@testable import sangaku

@Suite("Export: screens", .serialized)
@MainActor
struct ExportScreenTests {
    private static let fixture = PreviewFixtures.make()
    private var fixture: PreviewFixtures.Handles { Self.fixture }

    private func environment<V: View>(_ view: V) -> some View {
        view.appEnvironment(fixture.state)
            .environment(\.mathContext, fixture.mathContext)
            .modelContainer(fixture.state.container)
    }

    /// With `SANGAKU_PREVIEW_DIR` set, writes PNGs for a visual check.
    private func render(_ name: String, width: CGFloat, dark: Bool = false, @ViewBuilder _ view: () -> some View) throws {
        let content = environment(view())
            .frame(width: width)
            .padding()
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, dark ? .dark : .light)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        let image = try #require(renderer.cgImage, "\(name) did not render")
        if let folder = ProcessInfo.processInfo.environment["SANGAKU_PREVIEW_DIR"] {
            try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: folder).appending(path: "\(name).png"))
        }
    }

    @Test("The words: what each export writes and runs, folders, outcomes; never \"passed\" or \"verified\"")
    func wording() {
        for kind in ExportKind.allCases {
            let text = ExportScreenWording.explanation(kind).lowercased()
            #expect(!text.contains("passed") && !text.contains("verified"), "\(kind)")
        }
        #expect(ExportScreenWording.folder(.empty).contains("commits them with git, in your name"))
        #expect(ExportScreenWording.folder(.refused("No.")) == "No.")
        #expect(ExportScreenWording.region("manuscript/main.tex#title")?.hasPrefix("The app's part of manuscript/main.tex") == true)
        #expect(ExportScreenWording.region("manuscript/preface.tex") == nil)
        let done = ExportOutcome(kind: .leanProject, folder: "/x", written: ["a", "b"], at: .now)
        #expect(ExportScreenWording.outcome(done) == "Lean Project exported: 2 files written to /x. Committed with git.")
        let failed = ExportOutcome(kind: .hashtag, folder: "/x", error: .stopped, at: .now)
        #expect(ExportScreenWording.outcome(failed) == "hashtag Manuscript not exported. The export was stopped. Nothing was written to the folder.")
        #expect(ExportScreenWording.checks(ExportPreviewData.failedBuild).contains("FAIL every item has a label               lemma ch1-results.tex:40"))
        #expect(ExportScreenWording.counts(.init(errors: 1, undefined: 0, twice: 2, unresolved: 1, overfull: 1, pages: 1))
                == "LaTeX: 1 error, 0 undefined references, 2 labels defined twice, 1 unresolved link, 1 overfull box, 1 page.")
        let lean = ExportPlan(request: ExportRequest(problemID: UUID(), kind: .leanProject, folder: "/x"),
                              files: Array(repeating: ExportFile(path: "a", contents: ""), count: 5), regions: nil, folder: .empty)
        #expect(ExportScreenWording.toWrite(lean) == "5 files to write")
        let manuscript = ExportPlan(request: ExportRequest(problemID: UUID(), kind: .hashtag, folder: "/x"),
                                    files: [ExportFile(path: "a", contents: "")],
                                    regions: HashtagRegions(title: "", chapters: "", notation: ""), folder: .empty)
        #expect(ExportScreenWording.toWrite(manuscript) == "1 file and 3 regions to write")
        #expect(ExportScreenWording.kit("hashtag 1.0, bundled with the app (commit d7c5fba)")
                == "Created with hashtag 1.0, bundled with the app (commit d7c5fba).")
        #expect(ExportSettingsSection.describe(KitInfo(source: .bundled(commit: "d7c5fba"), version: "1.0"))
                == "Bundled with the app: hashtag 1.0 (commit d7c5fba)")
    }

    @Test("Smoke renders: the card, the plan and the report sheets, and the settings")
    func renders() async throws {
        let folder = ProcessExecutor.canonical(FileManager.default.temporaryDirectory.path) + "/sangaku-plan-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let people = fixture.state.problems.personIDs()
        let graph = StatementGraphState.read(problem: fixture.problem, people: people)
        let verification = VerificationState.read(problem: fixture.problem, people: people)
        try render("export-card", width: 340) { ExportCard(problem: fixture.problem, graph: graph, verification: verification) }
        try render("export-card-dark", width: 340, dark: true) {
            ExportCard(problem: fixture.problem, graph: graph, verification: verification)
        }
        for kind in ExportKind.allCases {
            let plan = try await fixture.state.export.plan(ExportRequest(problemID: fixture.problem.stableID, kind: kind, folder: folder))
            #expect(plan.folder == .empty)
            try render("export-plan-\(kind.rawValue)", width: 640) { ExportPlanSheet(problem: fixture.problem, kind: kind, plan: plan) }
        }
        try render("export-report", width: 640) {
            ExportReportSheet(problem: fixture.problem, outcome: ExportOutcome(
                kind: .hashtag, folder: folder, error: .build(ExportPreviewData.failedBuild),
                report: ExportPreviewData.failedBuild, at: .now))
        }
        try render("export-settings", width: 560) { Form { ExportSettingsSection(settings: fixture.state.toolSettings) }.formStyle(.grouped) }
    }

    @Test("The card and the menu go through one handler: open a plan, show the report, stop")
    func intents() {
        let window = WindowState()
        window.select(problem: fixture.problem)
        ExportIntentHandler.perform(.open(.leanProject), window: window, export: fixture.state.export)
        #expect(window.exportSheet == .plan(.leanProject))
        ExportIntentHandler.perform(.showReport, window: window, export: fixture.state.export)
        #expect(window.exportSheet == .report)
        window.select(problem: fixture.problem)
        #expect(window.exportSheet == nil, "choosing a problem closes the sheet")
    }

    @Test("Settings: five tabs in order, each page a form that fits the screen")
    func settingsTabs() throws {
        #expect(SettingsTab.allCases.map(\.title) == ["Models", "Lean", "Computations", "Limits", "Export"])
        #expect(Set(SettingsTab.allCases.map(\.systemImage)).count == SettingsTab.allCases.count)
        let settings = fixture.state.toolSettings
        let pages: [(String, AnyView)] = [
            ("lean", AnyView(SettingsPage { LeanSettingsSection(lean: fixture.state.lean, settings: settings) })),
            ("computations", AnyView(SettingsPage { ToolSettingsSection(settings: settings) })),
            ("limits", AnyView(SettingsPage { LimitsSettingsSection(settings: settings) })),
            ("export", AnyView(SettingsPage { ExportSettingsSection(settings: settings) })),
        ]
        for (name, page) in pages {
            let size = NSHostingController(rootView: environment(page)).sizeThatFits(in: .zero)
            #expect(size.width <= 600 && size.height <= 600, "\(name): \(size)")
            try render("settings-\(name)", width: 560) { page }
        }
    }

    @Test("The plan sheet fits a window of the minimum size")
    func fits() {
        let size = NSHostingController(rootView: environment(ExportPlanSheet(problem: fixture.problem, kind: .hashtag)))
            .sizeThatFits(in: .zero)
        #expect(size.width <= 700 && size.height <= WindowRoot.minimumHeight + 200, "\(size)")
    }
}
