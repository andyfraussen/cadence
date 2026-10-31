import Foundation
import LocalAuthentication
import Security

/// Cursor and Claude Code use the file-based login keychain. LAContext alone
/// only suppresses UI for the data-protection keychain, so legacy reads also
/// need SecKeychainSetUserInteractionAllowed, despite its deprecation.
enum KeychainReader {
    private static let interactionLock = NSRecursiveLock()

    static func copyMatching(_ query: [String: Any], allowPrompt: Bool, result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        withInteraction(allowed: allowPrompt) { context in
            var query = query
            query[kSecUseAuthenticationContext as String] = context
            return SecItemCopyMatching(query as CFDictionary, result)
        }
    }

    /// Serialize all our reads because the legacy setting is process-wide.
    /// Keep blocking credential reads on the caller's worker thread. Restore
    /// the prior setting even when a read fails or is cancelled.
    /// If the policy cannot be applied, fail before reading any credentials.
    static func withInteraction(allowed: Bool, operation: (LAContext) -> OSStatus) -> OSStatus {
        interactionLock.lock()
        defer { interactionLock.unlock() }
        var previous = DarwinBoolean(false)
        let readStatus = SecKeychainGetUserInteractionAllowed(&previous)
        guard readStatus == errSecSuccess else { return readStatus }
        let setStatus = SecKeychainSetUserInteractionAllowed(allowed)
        guard setStatus == errSecSuccess else { return setStatus }
        defer { SecKeychainSetUserInteractionAllowed(previous.boolValue) }

        let context = LAContext()
        context.interactionNotAllowed = !allowed
        return operation(context)
    }
}
