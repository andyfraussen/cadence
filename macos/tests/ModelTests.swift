import Foundation

@MainActor
final class Pending<Value> {
    private var continuations: [CheckedContinuation<Value, Error>] = []
    var count: Int { continuations.count }
    func load() async throws -> Value {
        try await withCheckedThrowingContinuation { continuations.append($0) }
    }
    func complete(_ result: Result<Value, Error>) {
        continuations.removeFirst().resume(with: result)
    }
}

@main
struct ModelTests {
    @MainActor
    static func main() async throws {
        let suite = "dev.fraussen.cadence.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "showGrok")
        defaults.set("manual", forKey: "authMode")
        defaults.set("manual", forKey: "authSource")
        let monthly = Pending<[Quota]>()
        let grok = Pending<Quota>()
        var token = "account-a"
        var authFailure = false
        var requestedTokens: [String] = []
        let model = AppModel(defaults: defaults, tokenLoader: {
            if authFailure { throw UsageError.message("Sign in to Cursor") }
            return token
        },
                             monthlyLoader: { token in requestedTokens.append(token); return try await monthly.load() },
                             grokLoader: { _ in try await grok.load() })
        precondition(defaults.object(forKey: "authMode") == nil && defaults.object(forKey: "authSource") == nil, "Legacy manual preferences removed without Keychain access")
        precondition(model.syncStatus() == .idle, "No false connected status before first fetch")
        model.refresh()
        precondition(model.syncStatus() == .fetching, "Fetching status")
        await wait { monthly.count == 1 }
        precondition(monthly.count == 1, "Monthly starts")
        precondition(grok.count == 0, "Hidden Grok must not make requests")
        let now = Date()
        let quota = Quota(id: "C", name: "Cursor Models", used: 25, reset: now.addingTimeInterval(86400), updated: now)
        monthly.complete(.success([quota]))
        await wait { !model.refreshing }
        precondition(model.monthly.count == 1 && !model.refreshing, "Hidden Grok cannot block monthly publication")
        precondition(model.syncStatus(at: now) == .connected && model.lastSuccess == now, "Successful connection and timestamp")
        precondition(model.syncStatus(at: now.addingTimeInterval(181)) == .stale, "Status ages without another request")

        model.showGrok = true
        await wait { monthly.count == 1 && grok.count == 1 }
        monthly.complete(.failure(UsageError.message("Monthly unavailable")))
        await wait { !model.monthlyRefreshing }
        precondition(model.monthlyError == "Monthly unavailable" && model.monthly.count == 1, "Same-account failure retains balances")
        precondition(model.grokRefreshing, "Monthly failure publishes before slow Grok")
        model.refresh()
        await wait { monthly.count == 1 }
        precondition(grok.count == 1, "Retry monthly while Grok pending without duplicate Grok request")
        monthly.complete(.success([quota]))
        await wait { !model.monthlyRefreshing }
        precondition(model.monthlyError == nil && model.grok == nil, "Monthly recovery publishes before Grok")
        grok.complete(.failure(UsageError.message("Grok unavailable")))
        await wait { !model.refreshing }
        precondition(model.syncStatus() == .unavailable && model.hasProblem, "Grok failure affects visible sync health")

        model.refresh()
        await wait { monthly.count == 1 && grok.count == 1 }
        grok.complete(.success(quota))
        await wait { !model.grokRefreshing }
        precondition(model.grok != nil && model.monthlyRefreshing, "Grok publishes before slow monthly")
        monthly.complete(.success([quota]))
        await wait { !model.refreshing }

        model.refresh()
        await wait { monthly.count == 1 && grok.count == 1 }
        model.showGrok = false
        precondition(!model.grokRefreshing && model.grok == nil && model.grokError == nil, "Hide cancels and clears Grok")
        model.showGrok = true
        await wait { grok.count == 2 }
        grok.complete(.failure(UsageError.message("Obsolete hidden request")))
        grok.complete(.success(quota))
        monthly.complete(.success([quota]))
        await wait { !model.refreshing }
        precondition(model.grokError == nil && model.grok != nil, "Hidden request cannot overwrite re-enabled Grok")

        model.refresh()
        await wait { monthly.count == 1 && grok.count == 1 }
        token = "account-b"
        model.refresh()
        await wait { model.monthly.isEmpty && model.grok == nil }
        await wait { monthly.count == 2 && grok.count == 2 }
        monthly.complete(.success([quota]))
        grok.complete(.failure(UsageError.message("Old account error")))
        let newQuota = Quota(id: "C", name: "New account", used: 60, reset: quota.reset, updated: now)
        monthly.complete(.success([newQuota]))
        grok.complete(.success(newQuota))
        await wait { !model.refreshing }
        precondition(model.monthly.first?.used == 60 && model.grok?.used == 60 && model.grokError == nil, "Only new account results publish")
        precondition(requestedTokens.last == "account-b", "New token used after account change")

        model.refresh()
        await wait { monthly.count == 1 && grok.count == 1 }
        model.authenticationChanged()
        await wait { monthly.count == 2 && grok.count == 2 }
        monthly.complete(.failure(UsageError.message("Obsolete failure")))
        grok.complete(.success(quota))
        monthly.complete(.success([newQuota]))
        grok.complete(.success(newQuota))
        await wait { !model.refreshing }
        precondition(model.monthlyError == nil && model.grok?.used == 60, "Explicit auth invalidation rejects obsolete results")

        model.refresh()
        await wait { monthly.count == 1 && grok.count == 1 }
        authFailure = true
        model.refresh()
        await wait { model.monthly.isEmpty && model.grok == nil && !model.refreshing }
        precondition(model.monthlyError != nil, "Unavailable credentials report an error")
        monthly.complete(.success([quota]))
        grok.complete(.success(quota))
        authFailure = false
        model.refresh()
        await wait { monthly.count == 1 && grok.count == 1 }
        monthly.complete(.success([newQuota]))
        grok.complete(.success(newQuota))
        await wait { !model.refreshing }
        precondition(model.monthly.first?.used == 60 && model.syncStatus() == .connected, "Authentication recovers without obsolete results")
        authFailure = true
        model.refresh()
        await wait { model.syncStatus() == .unavailable && model.lastSuccess == nil }
        // Backoff: the failed cycle schedules automatic-refresh backoff.
        // refreshIfDue must skip while manual refresh still runs.
        model.refreshIfDue()
        precondition(!model.tokenLoading && monthly.count == 0 && grok.count == 0, "Backoff skips automatic refresh")
        model.refresh()
        precondition(model.tokenLoading, "Manual refresh bypasses backoff")
        await wait { !model.refreshing }
        // DisplayMode falls back to .both for corrupt stored values.
        defaults.set("corrupt-value", forKey: "displayMode")
        let fallback = AppModel(defaults: defaults, tokenLoader: { "x" })
        precondition(fallback.displayMode == .both, "Corrupt displayMode falls back to both")
        let demo = AppModel(demo: true, defaults: defaults, tokenLoader: { preconditionFailure("Demo must not authenticate") })
        demo.refresh()
        precondition(demo.syncStatus() == .demo, "Demo status does not claim a live connection")
        print("Passed model regression checks.")
    }

    @MainActor
    static func wait(_ condition: () -> Bool) async {
        for _ in 0..<2000 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        preconditionFailure("Timed out waiting for model state")
    }
}