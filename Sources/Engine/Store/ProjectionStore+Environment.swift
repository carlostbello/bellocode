import Foundation
import GRDB

// App-owned table of containerised execution (migration `v6-container-environments`, docs/features/containers.md).
// Kept by `rebuild()`. Holds no secret: registry passwords live in the Keychain.

extension ProjectionStore {
    private static let environmentEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    /// Every stored project environment, by project directory. Unreadable rows are skipped (the defaults apply).
    public func environments() async throws -> [String: StoredEnvironment] {
        let rows = try await writer.read { db in
            try Row.fetchAll(db, sql: "SELECT directory, json FROM app_environment").map { ($0["directory"] as String, $0["json"] as Data) }
        }
        var result: [String: StoredEnvironment] = [:]
        for (directory, data) in rows {
            if let value = try? JSONDecoder().decode(StoredEnvironment.self, from: data) { result[directory] = value }
        }
        return result
    }

    public func saveEnvironment(_ value: StoredEnvironment, directory: String) async throws {
        let data = try Self.environmentEncoder.encode(value)
        let now = Date().timeIntervalSince1970
        try await writer.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO app_environment (directory, updated, json) VALUES (?, ?, ?)", arguments: [directory, now, data])
        }
    }

    public func deleteEnvironment(directory: String) async throws {
        try await writer.write { db in
            try db.execute(sql: "DELETE FROM app_environment WHERE directory = ?", arguments: [directory])
        }
    }
}
