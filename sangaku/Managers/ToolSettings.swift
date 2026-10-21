import Foundation
import Synchronization

/// Where the tools are, where the Lean workspace is, and how long and how much a run may take. None of it is secret, so
/// it is kept in the app's preferences; tests and the fixture keep it in memory (`ToolSettings.Storage`).
@Observable
final class ToolSettings {
    nonisolated struct Values: Codable, Hashable, Sendable {
        /// Paths a person chose, overriding detection.
        var paths: [ToolID: String] = [:]
        /// The folder of the shared Lean workspace. No default: a person chooses it.
        var leanWorkspace: String?
        var computeSeconds: Double = RunLimits.compute.seconds
        var computeMemoryGiB: Double = Double(RunLimits.compute.memoryBytes) / Double(1 << 30)
        var leanSeconds: Double = RunLimits.lean.seconds
        var leanMemoryGiB: Double = Double(RunLimits.lean.memoryBytes) / Double(1 << 30)

        /// Limits are kept within reason, whatever was stored.
        func clamped() -> Values {
            var values = self
            values.computeSeconds = min(max(computeSeconds, 5), 3600)
            values.computeMemoryGiB = min(max(computeMemoryGiB, 0.25), 64)
            values.leanSeconds = min(max(leanSeconds, 30), 4 * 3600)
            values.leanMemoryGiB = min(max(leanMemoryGiB, 1), 128)
            return values
        }
    }

    /// Where the values are kept.
    nonisolated struct Storage: Sendable {
        let load: @Sendable () -> Values?
        let save: @Sendable (Values) -> Void

        static let key = "sangaku.tools"

        /// The app's preferences, for the person's own copy of the app.
        static var preferences: Storage {
            Storage(load: { JSONColumn.decode(Values.self, from: UserDefaults.standard.data(forKey: key)) },
                    save: { UserDefaults.standard.set(JSONColumn.encode($0), forKey: key) })
        }

        /// Kept for the life of the object only: tests, previews and the fixture.
        static func memory(_ initial: Values = Values()) -> Storage {
            let box = ValuesBox(initial)
            return Storage(load: { box.value }, save: { box.value = $0 })
        }
    }

    private(set) var values: Values
    @ObservationIgnored private let storage: Storage
    @ObservationIgnored let locator: ToolLocator

    init(storage: Storage, locator: ToolLocator = ToolLocator()) {
        self.storage = storage
        self.locator = locator
        values = (storage.load() ?? Values()).clamped()
    }

    func update(_ edit: (inout Values) -> Void) {
        var next = values
        edit(&next)
        next = next.clamped()
        guard next != values else { return }
        values = next
        storage.save(next)
    }

    /// Where a tool is: the person's choice if it can be run, else the first found in the usual places.
    func resolution(_ tool: ToolID) -> ToolResolution {
        locator.resolve(tool, chosen: values.paths[tool])
    }

    var computeLimits: RunLimits {
        RunLimits(seconds: values.computeSeconds, memoryBytes: UInt64(values.computeMemoryGiB * Double(1 << 30)),
                  outputBytes: RunLimits.compute.outputBytes, folderBytes: RunLimits.compute.folderBytes)
    }

    var leanLimits: RunLimits {
        RunLimits(seconds: values.leanSeconds, memoryBytes: UInt64(values.leanMemoryGiB * Double(1 << 30)),
                  outputBytes: RunLimits.lean.outputBytes, folderBytes: RunLimits.lean.folderBytes)
    }
}

/// Holds the in-memory values of `ToolSettings.Storage.memory`.
nonisolated final class ValuesBox: Sendable {
    private let state: Mutex<ToolSettings.Values>

    init(_ value: ToolSettings.Values) { state = Mutex(value) }

    var value: ToolSettings.Values {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }
}

/// Where a tool was found, or why it cannot be used.
nonisolated enum ToolResolution: Hashable, Sendable {
    case ready(path: String, chosen: Bool)
    case notSetUp
    case notExecutable(String)

    var path: String? {
        if case .ready(let path, _) = self { path } else { nil }
    }
}

/// Finds tools without a shell or a `PATH`: an app opened from the Finder has neither the person's shell setup nor
/// their aliases (`gap` may be `git apply` there). Never `/usr/bin/python3`, which asks to install developer tools.
nonisolated struct ToolLocator: Sendable {
    var home: String = NSHomeDirectory()
    var isExecutable: @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }

    func candidates(_ tool: ToolID) -> [String] {
        switch tool {
        case .python:
            ["/opt/homebrew/bin/python3", "/usr/local/bin/python3",
             "/Library/Frameworks/Python.framework/Versions/Current/bin/python3"]
        case .gap: ["/opt/homebrew/bin/gap", "/usr/local/bin/gap"]
        case .sage: ["/opt/homebrew/bin/sage", "/usr/local/bin/sage"]
        case .elan: [home + "/.elan/bin/elan"]
        }
    }

    func resolve(_ tool: ToolID, chosen: String?) -> ToolResolution {
        if let chosen, !chosen.isEmpty {
            return isExecutable(chosen) && chosen.hasPrefix("/") ? .ready(path: chosen, chosen: true) : .notExecutable(chosen)
        }
        return candidates(tool).first(where: isExecutable).map { .ready(path: $0, chosen: false) } ?? .notSetUp
    }

    /// The folder a tool's installation lives in, which its sandbox may read: two levels above the program
    /// (`…/bin/gap` gives `…`). Nil when that would open the home folder, a folder above it, or one of the home
    /// folder's own visible folders (`~/Documents` for `~/Documents/bin/python3`) to the run; hidden tool folders such
    /// as `~/.local` stay readable.
    func installationRoot(of executable: String) -> String? {
        let real = ProcessExecutor.canonical(executable)
        let root = ((real as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
        let realHome = ProcessExecutor.canonical(home)
        guard root.count > 1, root != realHome, !realHome.hasPrefix(root + "/") else { return nil }
        let parent = (root as NSString).deletingLastPathComponent
        if parent == realHome, !(root as NSString).lastPathComponent.hasPrefix(".") { return nil }
        return root
    }
}
