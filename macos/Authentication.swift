import CommonCrypto
import Foundation
import LocalAuthentication
import Security
import SQLite3

enum Authentication {
    /// Set by manual refresh. The 60s timer leaves this false so a dismissed
    /// keychain dialog is not shown again until the user presses Retry.
    private final class PromptGate: @unchecked Sendable {
        private let lock = NSLock()
        private var allowed = true
        var promptsAllowed: Bool {
            get { lock.lock(); defer { lock.unlock() }; return allowed }
            set { lock.lock(); allowed = newValue; lock.unlock() }
        }
    }
    private static let prompts = PromptGate()
    static var promptsAllowed: Bool {
        get { prompts.promptsAllowed }
        set { prompts.promptsAllowed = newValue }
    }

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
    /// Keychain UI, when needed, is presented from the main thread.
    static func automaticToken() async throws -> String {
        let allowPrompt = promptsAllowed
        let paths = candidatePaths()
        return try await Task.detached(priority: .utility) {
            var lastError: Error = UsageError.message("Open the Cursor desktop app and sign in, then retry.")
            var sawInstall = false
            for path in paths {
                guard FileManager.default.fileExists(atPath: path) else { continue }
                sawInstall = true
                do { return try readToken(at: path, allowPrompt: allowPrompt) }
                catch { lastError = error }
                // A readable install owns the error. Falling through to a
                // missing Nightly copy would hide a keychain cancellation.
                break
            }
            if !sawInstall { throw UsageError.message("Open the Cursor desktop app and sign in, then retry.") }
            throw lastError
        }.value
    }

    /// Synchronous reader for a single database file. Exposed for tests with
    /// temporary SQLite fixtures. `password` injects the keychain secret so
    /// tests never touch the login keychain.
    static func readToken(at path: String, allowPrompt: Bool = true, password: Data? = nil) throws -> String {
        // Prefer a direct read-only open; fall back to a temp copy when the
        // live database is locked or WAL recovery needs write access.
        let raw: String
        do {
            raw = try queryToken(at: path)
        } catch {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("cadence-state-\(UUID().uuidString).vscdb").path
            do {
                try FileManager.default.copyItem(atPath: path, toPath: tmp)
                defer { try? FileManager.default.removeItem(atPath: tmp) }
                raw = try queryToken(at: tmp)
            } catch {
                // Fall through to the original error below when the copy also fails.
                throw error
            }
        }
        return try present(raw, allowPrompt: allowPrompt, password: password)
    }

    private static func present(_ raw: String, allowPrompt: Bool, password: Data?) throws -> String {
        let cleaned = try cleanToken(raw)
        guard cleaned.hasPrefix(CursorSessionSeal.envelope) else { return cleaned }
        if let password { return try CursorSessionSeal.decrypt(cleaned, password: password) }
        return try CursorSessionSeal.unlock(cleaned, allowPrompt: allowPrompt)
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
              sqlite3_step(statement) == SQLITE_ROW else {
            throw UsageError.message("Cursor login not found. Open Cursor and sign in.")
        }
        guard let value = sqlite3_column_text(statement, 0) else {
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

/// Cursor seals `cursorAuth/accessToken` as `cursor-safe-storage:v1:` plus
/// base64 of Chromium's `v10` ciphertext. The AES key is PBKDF2-HMAC-SHA1 of
/// the "Cursor Safe Storage" login-keychain password (salt `saltysalt`,
/// 1003 rounds, 16 bytes). The dialog asks for this Mac's login password.
enum CursorSessionSeal {
    static let envelope = "cursor-safe-storage:v1:"
    static let macPasswordHelp = "Enter the password for this Mac when asked. Google sign-in does not unlock this prompt. Press Retry, use your Mac login password, and choose Always Allow."

    private static let salt = Data("saltysalt".utf8)
    private static let iv = Data(repeating: 0x20, count: 16)
    private static let iterations: UInt32 = 1003
    private static let identities: [(service: String, account: String)] = [
        ("Cursor Safe Storage", "Cursor Key"),
        ("Cursor Safe Storage", "Cursor"),
        ("Chromium Safe Storage", "Chromium Key"),
    ]
    private final class KeyCache: @unchecked Sendable {
        private let lock = NSLock()
        private var password: Data?
        func get() -> Data? { lock.lock(); defer { lock.unlock() }; return password }
        func set(_ password: Data?) { lock.lock(); defer { lock.unlock() }; self.password = password }
    }
    private static let keys = KeyCache()

    private enum OpenFailure: Error { case wrongKey }

    private enum KeychainResult {
        case data(Data)
        case missing
        case needsPrompt
        case cancelled
    }

    static func decrypt(_ stored: String, password: Data) throws -> String {
        do { return try open(stored, password: password) }
        catch is OpenFailure { throw UsageError.message("Cursor’s saved session could not be unlocked.") }
    }

    /// Reads the login keychain, prompting only when `allowPrompt` is set.
    /// A password that successfully opens the session is kept in memory so
    /// later refreshes do not ask again.
    static func unlock(_ stored: String, allowPrompt: Bool) throws -> String {
        if let cached = cached() {
            if let token = try? open(stored, password: cached) { return token }
            store(nil)
        }
        var locked: [(service: String, account: String)] = []
        for identity in identities {
            switch lookup(service: identity.service, account: identity.account, prompt: false) {
            case .data(let password):
                if let token = try? open(stored, password: password) {
                    store(password)
                    return token
                }
            case .missing:
                continue
            case .needsPrompt, .cancelled:
                locked.append(identity)
            }
        }
        guard allowPrompt, !locked.isEmpty else {
            throw UsageError.message(locked.isEmpty
                ? "Cursor’s saved session could not be unlocked. Open Cursor and sign in, then press Retry."
                : macPasswordHelp)
        }
        for identity in locked {
            switch lookup(service: identity.service, account: identity.account, prompt: true) {
            case .data(let password):
                if let token = try? open(stored, password: password) {
                    store(password)
                    return token
                }
            case .missing:
                continue
            case .cancelled, .needsPrompt:
                throw UsageError.message(macPasswordHelp)
            }
        }
        throw UsageError.message("Cursor’s saved session could not be unlocked. Open Cursor and sign in, then press Retry.")
    }

    private static func open(_ stored: String, password: Data) throws -> String {
        guard stored.hasPrefix(envelope),
              let cipher = Data(base64Encoded: String(stored.dropFirst(envelope.count)), options: .ignoreUnknownCharacters),
              cipher.starts(with: Data("v10".utf8)), cipher.count > 3 else {
            throw UsageError.message("Cursor’s saved session uses an unrecognized lock. Open Cursor and sign in, then press Retry.")
        }
        let key = try deriveKey(password)
        let body = cipher.dropFirst(3)
        var output = Data(count: body.count)
        var moved = 0
        let status: CCCryptorStatus = output.withUnsafeMutableBytes { outputBytes in
            body.withUnsafeBytes { bodyBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                keyBytes.baseAddress, key.count, ivBytes.baseAddress,
                                bodyBytes.baseAddress, body.count,
                                outputBytes.baseAddress, outputBytes.count, &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw OpenFailure.wrongKey }
        output.removeSubrange(moved..<output.count)
        guard let text = String(data: output, encoding: .utf8) else { throw OpenFailure.wrongKey }
        return try Authentication.cleanToken(text)
    }

    private static func deriveKey(_ password: Data) throws -> Data {
        var key = Data(count: 16)
        let status: Int32 = password.withUnsafeBytes { passwordBytes in
            salt.withUnsafeBytes { saltBytes in
                key.withUnsafeMutableBytes { keyBytes in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                         passwordBytes.bindMemory(to: Int8.self).baseAddress, password.count,
                                         saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                         CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), iterations,
                                         keyBytes.bindMemory(to: UInt8.self).baseAddress, 16)
                }
            }
        }
        guard status == kCCSuccess else { throw OpenFailure.wrongKey }
        return key
    }

    private static func lookup(service: String, account: String, prompt: Bool) -> KeychainResult {
        if Thread.isMainThread { return lookupOnThisThread(service: service, account: account, prompt: prompt) }
        return DispatchQueue.main.sync { lookupOnThisThread(service: service, account: account, prompt: prompt) }
    }

    private static func lookupOnThisThread(service: String, account: String, prompt: Bool) -> KeychainResult {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if !prompt {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, !data.isEmpty else { return .missing }
            return .data(data)
        case errSecItemNotFound:
            return .missing
        case errSecUserCanceled:
            return .cancelled
        case errSecInteractionNotAllowed, errSecAuthFailed:
            return .needsPrompt
        default:
            return prompt ? .cancelled : .needsPrompt
        }
    }

    private static func cached() -> Data? { keys.get() }

    private static func store(_ password: Data?) { keys.set(password) }
}
