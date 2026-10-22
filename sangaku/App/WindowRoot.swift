import SwiftData
import SwiftUI

/// One window: sidebar, workspace and the proof-structure inspector. Owns the window's state.
///
/// The window is never narrower than its columns need. If it were, the split view would keep its own minimum
/// width and be centred in the window, cutting off the sidebar and the inspector at the window's edges.
/// On macOS 26 the sidebar floats over the workspace, and the split view's minimum counts the sidebar's width
/// twice: once as a column, once as the workspace's inset beneath it (measured: 816 pt with a 268 pt sidebar
/// and no inspector; the inspector adds its own width). So the side columns have fixed widths, and the
/// window's minimum is computed from them, with or without the inspector.
struct WindowRoot: View {
    static let sidebarWidth: CGFloat = 240
    /// The floating sidebar is drawn this much wider than its set width (measured on macOS 26).
    static let sidebarMargin: CGFloat = 8
    /// Three statement boxes side by side in the proof-structure graph.
    static let inspectorWidth: CGFloat = 340
    /// The narrowest the workspace's content can be: every row in it wraps or truncates to this.
    static let contentMinWidth: CGFloat = 300
    static let minimumHeight: CGFloat = 600

    static func minimumWidth(inspector: Bool) -> CGFloat {
        2 * (sidebarWidth + sidebarMargin) + contentMinWidth + (inspector ? inspectorWidth : 0)
    }

    @State private var window = WindowState()
    @Environment(\.problemManager) private var problems
    #if DEBUG
    @Environment(\.openSettings) private var openSettings
    #endif

    var body: some View {
        NavigationSplitView {
            SidebarView(window: window)
                .navigationSplitViewColumnWidth(Self.sidebarWidth)
        } detail: {
            WorkspaceDetail(window: window)
                .safeAreaInset(edge: .top, spacing: 0) {
                    VStack(spacing: 0) {
                        SaveErrorBanner()
                        VerificationNoticeBanner(window: window)
                    }
                }
                // On the detail column, not the split view, so the inspector is a column of the same split view
                // and its width is not counted twice.
                .inspector(isPresented: $window.inspectorPresented) {
                    InspectorPanel(window: window)
                        .inspectorColumnWidth(Self.inspectorWidth)
                }
        }
        .toolbar { WorkspaceToolbar(window: window) }
        // On the whole split view, so the inspector's actions reach it too.
        .verificationSheets(window: window)
        .exportSheets(window: window)
        .focusedSceneValue(\.windowState, window)
        // Showing the inspector raises the minimum, and the window widens to make room.
        .frame(minWidth: Self.minimumWidth(inspector: window.inspectorPresented), minHeight: Self.minimumHeight)
        .task {
            // A new window opens on the most recent problem.
            if window.selectedProblemID == nil { window.select(problem: problems?.mostRecentProblem()) }
            #if DEBUG
            if let view = DebugSnapshot.startView { window.activeView = view }
            if let kind = DebugSnapshot.exportSheet { window.exportSheet = .plan(kind) }
            if DebugSnapshot.opensSettings { openSettings() }
            #endif
        }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: DebugSnapshot.toggleInspector)) { _ in
            window.inspectorPresented.toggle()
        }
        #endif
    }
}

/// Shown while the store cannot be saved: the work is not lost yet, and the user should know.
private struct SaveErrorBanner: View {
    @Environment(\.saveScheduler) private var saves

    var body: some View {
        if let saves, let error = saves.lastError {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .accessibilityHidden(true)
                Text("Changes could not be saved: \(error) Retrying automatically.")
                    .lineLimit(2)
                Spacer()
                Button("Retry Now") { saves.flush() }
            }
            .font(.callout)
            .foregroundStyle(ColorToken.refuted.color)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(ColorToken.refutedFill.color)
            .accessibilityElement(children: .combine)
        }
    }
}

#if DEBUG
#Preview("Window", traits: .fixture, .fixedLayout(width: 1280, height: 820)) {
    WindowRoot()
}

#Preview("Window, empty") {
    let state = AppState(storage: .inMemory)
    WindowRoot()
        .appEnvironment(state)
        .modelContainer(state.container)
        .frame(width: 1100, height: 700)
}
#endif

/// The active workspace view for the selected problem.
private struct WorkspaceDetail: View {
    let window: WindowState
    @Environment(\.problemManager) private var problems

    var body: some View {
        if let id = window.selectedProblemID {
            ProblemScope(id: id) { problem in
                WorkspaceContent(problem: problem, window: window)
            }
            .navigationTitle(window.activeView.title)
        } else {
            ContentUnavailableView {
                Label("No problem selected", systemImage: "function")
            } description: {
                Text("Create a problem to pin its statement and start working on it.")
            } actions: {
                Button("New Problem") {
                    if let problems { window.createProblem(using: problems) }
                }
            }
        }
    }
}

/// The active view, with the problem editor available whichever view is showing.
private struct WorkspaceContent: View {
    let problem: Problem
    let window: WindowState

    var body: some View {
        @Bindable var window = window
        Group {
            switch window.activeView {
            case .thread:
                ThreadView(problem: problem, window: window)
            case .compare:
                CompareView(problem: problem, window: window)
            case .review:
                ReviewView(problem: problem, window: window)
            case .branches:
                BranchesView(problem: problem, window: window)
            }
        }
        .sheet(isPresented: $window.isEditingProblem) {
            ProblemEditor(problem: problem)
        }
        .branchSheets(problem: problem, window: window)
    }
}
