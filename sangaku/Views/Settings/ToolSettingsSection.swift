import SwiftUI
import UniformTypeIdentifiers

/// Settings ▸ Tools: where Python, GAP and Sage are, as found or as chosen, and how long and how much memory a
/// computation may use. Every run is sandboxed whatever is chosen here.
struct ToolSettingsSection: View {
    let settings: ToolSettings

    var body: some View {
        Section {
            ForEach([ToolID.python, .gap, .sage], id: \.self) { tool in
                ToolPathRow(tool: tool, settings: settings)
            }
        } header: {
            Text("Computation tools")
        } footer: {
            Text("A computation runs only when you click Run on its code, offline, and can write only to a folder of its own.")
                .foregroundStyle(.secondary)
        }
        Section("Limits") {
            LimitRow(title: "Computation time", value: Binding(get: { settings.values.computeSeconds },
                                                              set: { value in settings.update { $0.computeSeconds = value } }),
                     unit: "s", step: 30)
            LimitRow(title: "Computation memory", value: Binding(get: { settings.values.computeMemoryGiB },
                                                                set: { value in settings.update { $0.computeMemoryGiB = value } }),
                     unit: "GiB", step: 0.5)
            LimitRow(title: "Lean check time", value: Binding(get: { settings.values.leanSeconds },
                                                             set: { value in settings.update { $0.leanSeconds = value } }),
                     unit: "s", step: 60)
            LimitRow(title: "Lean check memory", value: Binding(get: { settings.values.leanMemoryGiB },
                                                               set: { value in settings.update { $0.leanMemoryGiB = value } }),
                     unit: "GiB", step: 1)
        }
    }
}

/// One tool: where it is and whether it can run, with Choose… and Use Detected.
private struct ToolPathRow: View {
    let tool: ToolID
    let settings: ToolSettings

    @State private var choosing = false

    var body: some View {
        let resolution = settings.resolution(tool)
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(tool.displayName)
                Group {
                    switch resolution {
                    case .ready(let path, let chosen):
                        Text(path + (chosen ? "" : " (found)"))
                    case .notSetUp:
                        Text("Not set up: not found in " + Prose.list(settings.locator.candidates(tool)) + ".")
                    case .notExecutable(let path):
                        Text("\(path) is not a program that can be run.")
                            .foregroundStyle(ColorToken.refuted.color)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            }
            Spacer()
            if settings.values.paths[tool] != nil {
                Button("Use Detected") { settings.update { $0.paths[tool] = nil } }
            }
            Button("Choose…") { choosing = true }
        }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.unixExecutable, .item]) { result in
            if case .success(let url) = result { settings.update { $0.paths[tool] = url.path } }
        }
        // A group a VoiceOver user enters, so Choose… and Use Detected stay reachable on their own.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(tool.displayName)
    }
}

private struct LimitRow: View {
    let title: String
    @Binding var value: Double
    let unit: String
    let step: Double

    var body: some View {
        Stepper(value: $value, step: step) {
            HStack {
                Text(title)
                Spacer()
                Text("\(value.formatted(.number.precision(.fractionLength(0...2)))) \(unit)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }
}
