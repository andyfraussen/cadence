import Foundation
import LocalAuthentication
import Security

/// Reads Claude plan limits (5-hour session and weekly) for the account
/// signed in to Claude Code. Cadence only reads Claude Code's access token;
/// it never refreshes, rewrites, or stores it. Refreshing would rotate the
/// refresh token and could sign Claude Code out.
enum ClaudeUsage {
    static let keychainService = "Claude Code-credentials"
    /// Automatic checks are at least this far apart; the usage endpoint
    /// rate-limits aggressively and plan limits move slowly.
    static let checkInterval: TimeInterval = 300
    static let maxBackoff: TimeInterval = 1800
    /// Longer than two check intervals plus a backoff step, so a healthy
    /// reading never flickers to stale between polls.
    static let staleAfter: TimeInterval = 900

    struct RateLimited: LocalizedError {
        let retryAfter: TimeInterval?
        var errorDescription: String? { "Claude is rate limiting limit checks. Cadence will try again later." }
    }

    static func credentialsFile() -> String {
        let environment = ProcessInfo.processInfo.environment
        let directory = environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : $0 }
            ?? FileManager.default.homeDirectoryForCurrentUser.path + "/.claude"
        return directory + "/.credentials.json"
    }

    /// True when Claude Code has left a sign-in behind. The keychain probe asks
    /// for attributes only and forbids UI, so detection never shows a dialog.
    static func isInstalled() -> Bool {
        if FileManager.default.fileExists(atPath: credentialsFile()) { return true }
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context,
        ]
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess || status == errSecInteractionNotAllowed || status == errSecAuthFailed
    }

    // MARK: Credentials

    enum Credential: Equatable {
        case token(String)
        case expired
        case unusable
    }

    /// Extracts the OAuth access token from Claude Code's credential JSON.
    /// API-key setups have no `claudeAiOauth` entry and no plan limits to show.
    static func credential(from data: Data, at now: Date = Date()) -> Credential {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { return .unusable }
        if let expiresAt = UsageParser.percent(oauth["expiresAt"]), expiresAt / 1000 <= now.timeIntervalSince1970 {
            return .expired
        }
        return .token(token)
    }

    private enum KeychainResult {
        case data(Data), missing, needsPrompt, cancelled
    }

    private static func keychainData(prompt: Bool) -> KeychainResult {
        // Keychain UI belongs on the main thread, like the Cursor lookup.
        if Thread.isMainThread { return keychainDataOnThisThread(prompt: prompt) }
        return DispatchQueue.main.sync { keychainDataOnThisThread(prompt: prompt) }
    }

    private static func keychainDataOnThisThread(prompt: Bool) -> KeychainResult {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if !prompt {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        }
        var item: CFTypeRef?
        switch SecItemCopyMatching(query as CFDictionary, &item) {
        case errSecSuccess:
            guard let data = item as? Data, !data.isEmpty else { return .missing }
            return .data(data)
        case errSecItemNotFound: return .missing
        case errSecUserCanceled: return .cancelled
        case errSecInteractionNotAllowed, errSecAuthFailed: return .needsPrompt
        default: return prompt ? .cancelled : .needsPrompt
        }
    }

    static func accessToken(allowPrompt: Bool, at now: Date = Date()) throws -> String {
        var sawExpired = false, sawUnusable = false
        func consider(_ data: Data) -> String? {
            switch credential(from: data, at: now) {
            case .token(let token): return token
            case .expired: sawExpired = true
            case .unusable: sawUnusable = true
            }
            return nil
        }
        let keychain = keychainData(prompt: allowPrompt)
        if case .data(let data) = keychain, let token = consider(data) { return token }
        if let data = FileManager.default.contents(atPath: credentialsFile()), let token = consider(data) { return token }
        // Claude Code keeps the live token in the keychain and can leave an
        // outdated copy in the file, so an unread keychain explains the
        // failure better than an expired file.
        switch keychain {
        case .needsPrompt:
            throw UsageError.message("Press Retry to let Cadence read Claude Code’s sign-in from the keychain.")
        case .cancelled:
            throw UsageError.message("Cadence was not allowed to read Claude Code’s sign-in. Press Retry and choose Always Allow.")
        default: break
        }
        if sawExpired {
            throw UsageError.message("Claude Code’s sign-in has expired. Use Claude Code once to renew it, then retry.")
        }
        if sawUnusable {
            throw UsageError.message("Claude Code is not signed in with a Claude subscription, so there are no plan limits to show.")
        }
        throw UsageError.message("Sign in to Claude Code (run claude, then /login) and retry.")
    }

    // MARK: Parsing

    private static let windows: [(key: String, label: String, minutes: Double)] = [
        ("five_hour", "5 hours", 300),
        ("seven_day", "Weekly", 10080),
    ]

    static func parse(_ data: Data, at now: Date = Date()) throws -> [Quota] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageError.message("Claude returned an unrecognized limits response.")
        }
        // Function-local formatters: ISO8601DateFormatter is not Sendable.
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        var quotas: [Quota] = []
        for window in windows {
            // A window with no active period comes back null or without a reset.
            guard let entry = root[window.key] as? [String: Any],
                  let used = UsageParser.percent(entry["utilization"]), used <= 100,
                  let raw = entry["resets_at"] as? String,
                  let reset = fractional.date(from: raw) ?? plain.date(from: raw),
                  reset.timeIntervalSince(now) > -60,
                  reset.timeIntervalSince(now) <= window.minutes * 60 + 3600 else { continue }
            quotas.append(Quota(id: "claude-\(window.key)", name: "Claude · \(window.label)", used: used,
                                reset: reset, updated: now, windowMinutes: window.minutes,
                                staleAfter: staleAfter))
        }
        guard !quotas.isEmpty else { throw UsageError.message("Claude has no active usage windows for this account.") }
        return quotas.sorted { $0.reset < $1.reset }
    }

    // MARK: Network

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 20
        return URLSession(configuration: config, delegate: CursorAPIRedirectGuard(), delegateQueue: nil)
    }()

    static func fetch(allowPrompt: Bool) async throws -> [Quota] {
        let token = try await Task.detached(priority: .utility) {
            try accessToken(allowPrompt: allowPrompt)
        }.value
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("Cadence (macOS menu bar)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw UsageError.message("No response from Claude.") }
        switch response.statusCode {
        case 200: return try parse(data)
        case 401, 403: throw UsageError.message("Claude rejected the sign-in. Use Claude Code once to renew it, then retry.")
        case 429: throw RateLimited(retryAfter: response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init))
        default: throw UsageError.message("Claude API error (HTTP \(response.statusCode)). Try refreshing later.")
        }
    }
}
