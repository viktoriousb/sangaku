#if DEBUG
import AppKit

/// Debug builds launched with `-SangakuSnapshot <path>` write a PNG of their first window to `path` after a
/// short delay (`-SangakuSnapshotDelay <seconds>`, 3 by default) and quit. For checking the real window
/// (AppKit controls included) without screen recording. The glass side columns do not draw into the PNG, so
/// `<path>.layout.txt` lists the window's size and every split view column's width.
///
/// `-SangakuWindowSize <width>x<height>[@<seconds>]` resizes the first window after launch (the window's
/// minimum still applies), for checking narrow windows. `-SangakuToggleInspector <seconds>,<seconds>…` toggles the
/// inspector at those times after launch. `-SangakuCloseWindowAt <seconds>` closes the window then, so a session
/// can end with no window open (what the next launch restores).
///
/// Give every flag a value (`-SangakuFixture YES`): AppKit reads arguments in `-key value` pairs, and a flag
/// without one swallows the next flag, leaving a path that AppKit then tries to open as a document, in which
/// case no window opens.
enum DebugSnapshot {
    static let toggleInspector = Notification.Name("SangakuDebugToggleInspector")

    /// `-SangakuStartView <thread|compare|review|branches>`: the view new windows open on.
    static var startView: WorkspaceView? {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "-SangakuStartView"), flag + 1 < arguments.count else { return nil }
        return WorkspaceView(rawValue: arguments[flag + 1])
    }

    /// `-SangakuOpenExport <latex|hashtag|leanProject>`: new windows open that export's plan sheet.
    static var exportSheet: ExportKind? {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "-SangakuOpenExport"), flag + 1 < arguments.count else { return nil }
        return ExportKind(rawValue: arguments[flag + 1])
    }

    /// `-SangakuOpenSettings YES`: the first window opens Settings after launch, and the snapshot is of Settings.
    /// `-settings.tab <tab>` picks its tab for this launch only (the argument domain is never saved).
    static var opensSettings: Bool { CommandLine.arguments.contains("-SangakuOpenSettings") }

    static func scheduleIfRequested() {
        let arguments = CommandLine.arguments
        if let flag = arguments.firstIndex(of: "-SangakuToggleInspector"), flag + 1 < arguments.count {
            for time in arguments[flag + 1].split(separator: ",").compactMap({ Double($0) }) {
                DispatchQueue.main.asyncAfter(deadline: .now() + time) {
                    NotificationCenter.default.post(name: toggleInspector, object: nil)
                }
            }
        }
        if let flag = arguments.firstIndex(of: "-SangakuCloseWindowAt"), flag + 1 < arguments.count,
           let time = Double(arguments[flag + 1]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + time) {
                MainActor.assumeIsolated { NSApp.windows.first { $0.isVisible }?.performClose(nil) }
            }
        }
        if let flag = arguments.firstIndex(of: "-SangakuWindowSize"), flag + 1 < arguments.count {
            // `<width>x<height>`, optionally `@<seconds>` (0.5 by default).
            let spec = arguments[flag + 1].split(separator: "@")
            let parts = spec[0].split(separator: "x").compactMap { Double($0) }
            let time = spec.count > 1 ? Double(spec[1]) ?? 0.5 : 0.5
            if parts.count == 2 {
                DispatchQueue.main.asyncAfter(deadline: .now() + time) {
                    MainActor.assumeIsolated {
                        NSApp.windows.first { $0.isVisible }?.setContentSize(NSSize(width: parts[0], height: parts[1]))
                    }
                }
            }
        }
        guard let flag = arguments.firstIndex(of: "-SangakuSnapshot"), flag + 1 < arguments.count else { return }
        let path = arguments[flag + 1]
        let delay = arguments.firstIndex(of: "-SangakuSnapshotDelay").flatMap {
            $0 + 1 < arguments.count ? Double(arguments[$0 + 1]) : nil
        } ?? 3
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            MainActor.assumeIsolated {
                // The Settings window when it was opened, else the first window.
                let settings = opensSettings
                    ? NSApp.windows.first { $0.isVisible && ($0.identifier?.rawValue.contains("Settings") ?? false) } : nil
                if let window = settings ?? NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
                   let view = window.contentView {
                    if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                        view.cacheDisplay(in: view.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                    }
                    let others = NSApp.windows.filter { $0 !== window }.map {
                        "other window \($0.identifier?.rawValue ?? "none") visible=\($0.isVisible) \(Int($0.frame.width))x\(Int($0.frame.height))"
                    }
                    try? (layoutReport(window) + others.map { $0 + "\n" }.joined())
                        .write(toFile: path + ".layout.txt", atomically: true, encoding: .utf8)
                } else {
                    let windows = NSApp.windows.map { "\(type(of: $0)) visible=\($0.isVisible) \(Int($0.frame.width))x\(Int($0.frame.height))" }
                    try? (["no visible window"] + windows).joined(separator: "\n")
                        .write(toFile: path + ".layout.txt", atomically: true, encoding: .utf8)
                }
                NSApp.terminate(nil)
            }
        }
    }

    private static func layoutReport(_ window: NSWindow) -> String {
        var lines = ["window content \(Int(window.contentLayoutRect.width))x\(Int(window.contentLayoutRect.height))"
                     + ", minimum \(Int(window.contentMinSize.width))x\(Int(window.contentMinSize.height))"]
        func visit(_ view: NSView) {
            if let split = view as? NSSplitView {
                // In window coordinates: a split view starting left of 0 or ending past the window is clipped.
                let frame = split.convert(split.bounds, to: nil)
                let columns = split.arrangedSubviews.map { subview -> String in
                    if split.isSubviewCollapsed(subview) { return "collapsed" }
                    let column = subview.convert(subview.bounds, to: nil)
                    return "\(Int(column.minX))…\(Int(column.maxX))"
                }
                lines.append("split view \(Int(frame.minX))…\(Int(frame.maxX)) × \(Int(frame.minY))…\(Int(frame.maxY)): columns "
                             + columns.joined(separator: ", "))
            }
            view.subviews.forEach(visit)
        }
        if let root = window.contentView?.superview ?? window.contentView { visit(root) }
        return lines.joined(separator: "\n") + "\n"
    }
}
#endif
