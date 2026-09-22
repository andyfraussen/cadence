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
        defaults.set(false, forKey: "showCodex")
        defaults.set(true, forKey: "showCursor")
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
        // Fixed morning budget persists across restarts and holds steady intraday.
        let dailySuite = "dev.fraussen.cadence.daily.\(UUID().uuidString)"
        let dailyDefaults = UserDefaults(suiteName: dailySuite)!
        defer { dailyDefaults.removePersistentDomain(forName: dailySuite) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let dayModel = AppModel(defaults: dailyDefaults, tokenLoader: { "x" })
        let dayStart = calendar.date(from: DateComponents(year: 2026, month: 9, day: 17, hour: 8))!
        let dayAfternoon = calendar.date(from: DateComponents(year: 2026, month: 9, day: 17, hour: 18))!
        let dayNext = calendar.date(from: DateComponents(year: 2026, month: 9, day: 18, hour: 8))!
        let dayReset = calendar.startOfDay(for: dayStart).addingTimeInterval(20 * 86400)
        let dayMorningQuota = Quota(id: "C", name: "Cursor", used: 30, reset: dayReset, updated: dayStart)
        dayModel.recordDailySnapshots(for: [dayMorningQuota], at: dayStart, calendar: calendar)
        let morningBudget = dayModel.dailyInfo(for: dayMorningQuota, at: dayStart, calendar: calendar).budget
        precondition(morningBudget != nil && abs(morningBudget! - 3.5) < 0.000001, "Morning budget persists")
        let dayAfternoonQuota = Quota(id: "C", name: "Cursor", used: 32.1, reset: dayReset, updated: dayAfternoon)
        dayModel.recordDailySnapshots(for: [dayAfternoonQuota], at: dayAfternoon, calendar: calendar)
        let afternoonInfo = dayModel.dailyInfo(for: dayAfternoonQuota, at: dayAfternoon, calendar: calendar)
        precondition(abs((afternoonInfo.budget ?? -1) - 3.5) < 0.000001, "Intraday budget holds steady")
        precondition(abs(afternoonInfo.usedToday - 2.1) < 0.000001 && abs((afternoonInfo.available ?? -1) - 1.4) < 0.000001, "Intraday spend tracks morning baseline")
        // Reload survives restarts via UserDefaults.
        let reloaded = AppModel(defaults: dailyDefaults, tokenLoader: { "x" })
        let reloadedInfo = reloaded.dailyInfo(for: dayAfternoonQuota, at: dayAfternoon, calendar: calendar)
        precondition(abs((reloadedInfo.budget ?? -1) - 3.5) < 0.000001, "Budget survives restart")
        // Next morning redistributes from fresh remaining.
        let nextQuota = Quota(id: "C", name: "Cursor", used: 33.0, reset: dayReset, updated: dayNext)
        reloaded.recordDailySnapshots(for: [nextQuota], at: dayNext, calendar: calendar)
        let redistributed = reloaded.dailyInfo(for: nextQuota, at: dayNext, calendar: calendar)
        precondition(abs((redistributed.budget ?? -1) - 67.9 / 19.0) < 0.000001, "Savings and overspend redistribute tomorrow")
        let codexSuite = "dev.fraussen.cadence.codex.\(UUID().uuidString)"
        let codexDefaults = UserDefaults(suiteName: codexSuite)!
        defer { codexDefaults.removePersistentDomain(forName: codexSuite) }
        codexDefaults.set(true, forKey: "showCodex")
        codexDefaults.set(false, forKey: "showCursor")
        let codexPending = Pending<[Quota]>()
        let codexModel = AppModel(defaults: codexDefaults, tokenLoader: { preconditionFailure("Disabled Cursor must not authenticate") },
                                  codexLoader: { try await codexPending.load() })
        codexModel.refresh()
        await wait { codexPending.count == 1 }
        precondition(codexModel.codexRefreshing, "Codex refresh is independent")
        let codexQuota = Quota(id: "codex-primary", name: "Codex · Weekly", used: 33,
                               reset: Date().addingTimeInterval(7 * 86400), updated: Date())
        codexPending.complete(.success([codexQuota]))
        await wait { !codexModel.codexRefreshing }
        precondition(codexModel.codex.first?.remaining == 67 && codexModel.toolbarTitle.contains("Cx 67%"), "Codex publishes to menu bar")
        precondition(codexModel.syncStatus() == .connected && codexModel.dailyAnchors["codex-primary"] != nil,
                     "Codex-only mode is connected and records a daily baseline")
        let codexBudget = codexModel.dailyInfo(for: codexQuota).budget
        precondition(codexBudget != nil && codexModel.dailyInfo(for: codexQuota).usedToday == 0,
                     "Codex weekly pacing starts with a fixed budget")
        let codexLater = Quota(id: codexQuota.id, name: codexQuota.name, used: 34,
                               reset: codexQuota.reset, updated: Date())
        codexModel.recordDailySnapshots(for: [codexLater])
        let codexLaterInfo = codexModel.dailyInfo(for: codexLater)
        precondition(codexLaterInfo.budget == codexBudget && abs(codexLaterInfo.usedToday - 1) < 0.000001,
                     "Codex weekly usage grows against the fixed daily budget")
        // Regression: short windows (e.g. 5 hours) must also record a baseline
        // through the refresh path — the old display-name filter dropped them,
        // leaving a live estimate that shrank every refresh.
        codexModel.refreshCodex()
        await wait { codexPending.count == 1 }
        let shortQuota = Quota(id: "codex-primary", name: "Codex · 5 hours", used: 20,
                               reset: Date().addingTimeInterval(5 * 3600), updated: Date(),
                               windowMinutes: 300)
        codexPending.complete(.success([shortQuota]))
        await wait { !codexModel.codexRefreshing }
        let shortBudget = codexModel.dailyInfo(for: shortQuota).budget
        precondition(shortBudget == 80 && codexModel.dailyInfo(for: shortQuota).usedToday == 0,
                     "Short Codex windows record a fixed full-window baseline through refresh")
        let shortLater = Quota(id: shortQuota.id, name: shortQuota.name, used: 23.5,
                               reset: shortQuota.reset.addingTimeInterval(120), updated: Date(), windowMinutes: 300)
        codexModel.recordDailySnapshots(for: [shortLater])
        let shortLaterInfo = codexModel.dailyInfo(for: shortLater)
        precondition(shortLaterInfo.budget == shortBudget && abs(shortLaterInfo.usedToday - 3.5) < 0.000001,
                     "Short-window usage grows against the fixed budget, not a shrinking estimate")
        let reloadedCodex = AppModel(defaults: codexDefaults, tokenLoader: { "unused" }, codexLoader: { [] })
        precondition(reloadedCodex.dailyAnchors["codex-primary"] != nil && !reloadedCodex.showCursor,
                     "Codex baseline and disabled Cursor survive restart")
        codexModel.showCodex = false
        precondition(codexModel.codex.isEmpty && !codexModel.toolbarTitle.contains("Cx"), "Hiding Codex clears its display")
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
