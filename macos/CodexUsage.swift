import Foundation

/// Reads the signed-in Codex account through the documented local app-server.
/// Cadence never reads or stores Codex credentials.
enum CodexUsage {
    static func executables() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var paths = [ProcessInfo.processInfo.environment["CODEX_BIN"],
                     "/Applications/ChatGPT.app/Contents/Resources/codex",
                     home + "/Applications/ChatGPT.app/Contents/Resources/codex",
                     "/opt/homebrew/bin/codex", "/usr/local/bin/codex", home + "/.local/bin/codex",
                     home + "/.bun/bin/codex"].compactMap { $0 }
        let nvm = home + "/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvm) {
            paths += versions.sorted().reversed().map { nvm + "/" + $0 + "/bin/codex" }
        }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        paths += path.split(separator: ":").map { String($0) + "/codex" }
        var seen = Set<String>()
        return paths.filter { FileManager.default.isExecutableFile(atPath: $0) && seen.insert($0).inserted }
    }

    static func executable() -> String? {
        executables().first
    }

    static func parse(_ data: Data, at now: Date = Date()) throws -> [Quota] {
        guard let message = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = message["result"] as? [String: Any] else {
            throw UsageError.message("Codex returned an unrecognized limits response.")
        }
        let limits: [String: Any]?
        if let byId = result["rateLimitsByLimitId"] as? [String: Any] {
            limits = byId["codex"] as? [String: Any]
        } else {
            limits = result["rateLimits"] as? [String: Any]
        }
        guard let limits else { throw UsageError.message("No Codex limits are available for this account.") }
        var quotas: [Quota] = []
        for key in ["primary", "secondary"] {
            guard let window = limits[key] as? [String: Any],
                  let used = window["usedPercent"] as? Double,
                  let minutes = window["windowDurationMins"] as? Double,
                  let resetSeconds = window["resetsAt"] as? Double,
                  used.isFinite, (0...100).contains(used), minutes > 0, minutes.isFinite,
                  resetSeconds.isFinite, resetSeconds > now.timeIntervalSince1970 - 60 else { continue }
            let label: String
            if minutes >= 10080 { label = "Weekly" }
            else if minutes >= 1440 { let value = Int(minutes / 1440); label = "\(value) \(value == 1 ? "day" : "days")" }
            else if minutes >= 60 { let value = Int(minutes / 60); label = "\(value) \(value == 1 ? "hour" : "hours")" }
            else { let value = Int(minutes); label = "\(value) \(value == 1 ? "minute" : "minutes")" }
            quotas.append(Quota(id: "codex-\(key)", name: "Codex · \(label)", used: used,
                                reset: Date(timeIntervalSince1970: resetSeconds), updated: now,
                                windowMinutes: minutes))
        }
        guard !quotas.isEmpty else { throw UsageError.message("Codex has no active usage windows for this account.") }
        return quotas.sorted { $0.reset.timeIntervalSince(now) < $1.reset.timeIntervalSince(now) }
    }

    static func fetch() async throws -> [Quota] {
        try await Task.detached(priority: .utility) {
            try fetchBlocking()
        }.value
    }

    private static func fetchBlocking() throws -> [Quota] {
        let paths = executables()
        guard !paths.isEmpty else {
            throw UsageError.message("Install ChatGPT or the Codex CLI to show Codex limits.")
        }
        var lastError: Error = UsageError.message("Codex limits are unavailable.")
        for binary in paths {
            do { return try readLimits(using: binary) }
            catch { lastError = error }
        }
        throw lastError
    }

    private static func readLimits(using binary: String) throws -> [Quota] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["app-server", "--stdio"]
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        do { try process.run() }
        catch { throw UsageError.message("Could not start Codex. Update ChatGPT or the Codex CLI and retry.") }
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: timeout)
        defer {
            timeout.cancel()
            if process.isRunning { process.terminate() }
            try? input.fileHandleForWriting.close()
            try? output.fileHandleForReading.close()
            try? errors.fileHandleForReading.close()
        }
        let requests: [[String: Any]] = [
            ["method": "initialize", "id": 1, "params": ["clientInfo": ["name": "cadence", "title": "Cadence", "version": "1.3.2"]]],
            ["method": "initialized", "params": [:]],
            ["method": "account/rateLimits/read", "id": 2, "params": [:]]
        ]
        for request in requests {
            let data = try JSONSerialization.data(withJSONObject: request) + Data([10])
            input.fileHandleForWriting.write(data)
        }
        var buffer = Data()
        while process.isRunning || !buffer.isEmpty {
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            guard buffer.count < 1_000_000 else { throw UsageError.message("Codex response was too large.") }
            while let newline = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let id = message["id"] as? Int, id == 2 else { continue }
                if let error = message["error"] as? [String: Any] {
                    let detail = error["message"] as? String ?? "Unknown error"
                    throw UsageError.message("Codex could not read limits: \(detail)")
                }
                return try parse(line)
            }
        }
        throw UsageError.message("Codex did not return limits. Sign in to Codex and retry.")
    }
}
