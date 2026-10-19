import Foundation
import SwiftData

/// Builds the app's `ModelContainer`.
enum ModelContainerFactory {
    enum Storage {
        case disk(URL)
        case inMemory
    }

    /// The store lives under Application Support/sangaku, independent of the bundle ID, so renaming the
    /// bundle never strands data. Opening never deletes or replaces an existing store.
    static func defaultStoreURL() throws -> URL {
        let folder = URL.applicationSupportDirectory.appending(path: "sangaku", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appending(path: "sangaku.store")
    }

    static func make(_ storage: Storage) throws -> ModelContainer {
        let schema = Schema(versionedSchema: SangakuSchemaV1.self)
        let configuration = switch storage {
        case .disk(let url):
            ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        case .inMemory:
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        }
        let container = try ModelContainer(for: schema, migrationPlan: SangakuMigrationPlan.self,
                                           configurations: configuration)
        // Saves go through SaveScheduler's debounce, never SwiftData's own timer.
        container.mainContext.autosaveEnabled = false
        return container
    }
}
