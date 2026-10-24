import SwiftUI

/// Settings ▸ Export: the hashtag kit manuscripts are created with (the copy bundled with the app, or a kit folder
/// chosen here), and the tools exports run: pdfLaTeX for building, git for keeping the folder in git and committing
/// each export.
struct ExportSettingsSection: View {
    let settings: ToolSettings

    @State private var choosing = false

    var body: some View {
        let chosen = settings.values.hashtagKit
        let kit = Result { () throws(ExportError) in try HashtagKit.resolve(chosen) }
        Section {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("hashtag kit")
                    Group {
                        switch kit {
                        case .success(let kit): Text(Self.describe(kit))
                        case .failure: Text(chosen ?? "")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                }
                Spacer()
                if chosen != nil {
                    Button("Use Bundled") { settings.update { $0.hashtagKit = nil } }
                }
                Button("Choose…") { choosing = true }
                    .help("Use a hashtag kit folder instead of the copy bundled with the app")
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("hashtag kit")
            if case .failure(let error) = kit {
                Label(error.message, systemImage: "exclamationmark.circle")
                    .foregroundStyle(ColorToken.refuted.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ToolPathRow(tool: .pdflatex, settings: settings)
            ToolPathRow(tool: .git, settings: settings)
        } header: {
            Text("Export")
        } footer: {
            Text("The manuscript is built with the kit's build.sh and pdfLaTeX, offline in a sandbox that can write only to a folder of its own. Each export is committed in your git name (user.name and user.email), without your global git settings: hooks set there don't run on these commits.")
                .foregroundStyle(.secondary)
        }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { settings.update { $0.hashtagKit = url.path(percentEncoded: false) } }
        }
    }

    /// "Bundled with the app: hashtag 1.0 (commit d7c5fba)", or the chosen folder and its version.
    static func describe(_ kit: KitInfo) -> String {
        switch kit.source {
        case .bundled(let commit): "Bundled with the app: hashtag \(kit.version) (commit \(commit))"
        case .folder(let folder): folder + ": hashtag \(kit.version)"
        }
    }
}
