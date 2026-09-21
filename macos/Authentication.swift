import Foundation
import SQLite3

enum Authentication {
    static func isCursorInstalled() -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let appPaths = ["/Applications/Cursor.app", home + "/Applications/Cursor.app",
                        "/Applications/Cursor Nightly.app", home + "/Applications/Cursor Nightly.app"]
        return (candidatePaths() + appPaths).contains { FileManager.default.fileExists(atPath: $0) }
    }

    /// Ordered install locations to probe. `CURSOR_STATE_VSCDB_PATH` overrides
    /// for tests and custom installs when set to a non-empty value.
    static func candidatePaths() -> [String] {
        if let override = ProcessInfo.processInfo.environment["CURSOR_STATE_VSCDB_PATH"],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return [override]
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            home + "/Library/Application Support/Cursor/User/globalStorage/state.vscdb",
            home + "/Library/Application Support/Cursor Nightly/User/globalStorage/state.vscdb",
        ]
    }

    /// Async entry point for the app. Runs blocking SQLite I/O off the main
    /// actor so a locked Cursor database cannot freeze the menu bar.
    static func automaticToken() async throws -> String {
        let paths = candidatePaths()
        return try await Task.detached(priority: .utility) {
            var lastError: Error = UsageError.message("Open the Cursor desktop app and sign in, then retry.")
            for path in paths {
                do { return try readToken(at: path) }
                catch { lastError = error }
            }
            throw lastError
        }.value
    }

    /// Synchronous reader for a single database file. Exposed for tests with
    /// temporary SQLite fixtures.
    static func readToken(at path: String) throws -> String {
        // Prefer a direct read-only open; fall back to a temp copy when the
        // live database is locked or WAL recovery needs write access.
        do {
            return try cleanToken(queryToken(at: path))
        } catch {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("cadence-state-\(UUID().uuidString).vscdb").path
            do {
                try FileManager.default.copyItem(atPath: path, toPath: tmp)
                defer { try? FileManager.default.removeItem(atPath: tmp) }
                return try cleanToken(queryToken(at: tmp))
            } catch {
                // Fall through to the original error below when the copy also fails.
            }
            throw error
        }
    }

    private static func queryToken(at path: String) throws -> String {
        var database: OpaquePointer?
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            if let database { sqlite3_close(database) }
            throw UsageError.message("Open the Cursor desktop app and sign in, then retry.")
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 1000)
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken'", -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW, let value = sqlite3_column_text(statement, 0) else {
            throw UsageError.message("Cursor login not found. Open Cursor and sign in.")
        }
        return String(cString: value)
    }

    /// Trim whitespace and unwrap JSON-quoted storage values.
    /// Cursor's `state.vscdb` values are JSON-encoded, so tokens may arrive as
    /// `"eyJ..."` with surrounding quotes.
    static func cleanToken(_ raw: String) throws -> String {
        var token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw UsageError.message("Sign in to Cursor first.") }
        if token.hasPrefix("\"") && token.hasSuffix("\"") && token.count >= 2,
           let data = token.data(using: .utf8),
           let decoded = try? JSONSerialization.jsonObject(with: data) as? String {
            token = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
        } else if token.hasPrefix("\"") && token.hasSuffix("\"") && token.count >= 2 {
            token = String(token.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !token.isEmpty else { throw UsageError.message("Sign in to Cursor first.") }
        return token
    }
}
