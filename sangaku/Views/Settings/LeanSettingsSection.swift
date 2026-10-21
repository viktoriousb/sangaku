import SwiftUI

/// Settings ▸ Lean: the folder of the shared Lean workspace, where it stands, and fetching Mathlib into it. Fetching
/// uses the network and is started only here; checks then run offline.
struct LeanSettingsSection: View {
    let lean: LeanService
    let settings: ToolSettings

    @State private var choosing = false
    @State private var error: String?

    var body: some View {
        Section {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Workspace folder")
                    Text(settings.values.leanWorkspace ?? "Not chosen")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                Button("Choose…") { choosing = true }
                    .disabled(lean.fetch.isRunning)
            }
            status
            fetchRow
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(ColorToken.refuted.color)
            }
        } header: {
            Text("Lean")
        } footer: {
            Text("Fetch Mathlib downloads Lean \(LeanPin.toolchain.split(separator: ":").last ?? "") if elan lacks it, and Mathlib \(LeanPin.mathlibRev) with its compiled files from GitHub (several gigabytes; files already in ~/.cache/mathlib are reused). Checks run offline, in a sandbox that can write only to a folder of its own.")
                .foregroundStyle(.secondary)
        }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                settings.update { $0.leanWorkspace = url.path }
                lean.refreshWorkspace()
            }
        }
        .onAppear { lean.refreshWorkspace() }
    }

    @ViewBuilder private var status: some View {
        switch lean.workspace {
        case .ready(let record):
            Label("Lean \(record.environment.leanVersion) · Mathlib \(record.environment.mathlibRev), fetched \(record.fetchedAt.formatted(date: .abbreviated, time: .shortened)).",
                  systemImage: "checkmark.circle")
        case let other:
            Label(other.refusal ?? "", systemImage: "exclamationmark.circle")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var fetchRow: some View {
        let fetch = lean.fetch
        if fetch.isRunning {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    ProgressView(value: Double(fetch.step), total: Double(max(fetch.steps, 1)))
                    Button("Stop") { lean.stopFetch() }
                }
                Text("Step \(fetch.step) of \(fetch.steps): \(fetch.title)")
                    .font(.callout)
                if !fetch.line.isEmpty {
                    Text(fetch.line)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Fetching Mathlib, step \(fetch.step) of \(fetch.steps): \(fetch.title)")
        } else {
            HStack {
                if let failure = fetch.failure {
                    Label(failure, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(ColorToken.refuted.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button(lean.workspace.record == nil ? "Fetch Mathlib" : "Fetch Again") {
                    do throws(VerificationError) {
                        try lean.fetchMathlib()
                        error = nil
                    } catch {
                        self.error = error.message
                        VoiceOver.announce(error.message)
                    }
                }
                .disabled(settings.values.leanWorkspace == nil)
            }
        }
    }
}
