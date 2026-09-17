import AppKit
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    enum DisplayMode: String, CaseIterable {
        case both, limits, logo
    }
    @Published var monthly: [Quota] = []
    @Published var grok: Quota?
    @Published var monthlyError: String?
    @Published var grokError: String?
    @Published private(set) var monthlyRefreshing = false
    @Published private(set) var grokRefreshing = false
    @Published private(set) var tokenLoading = false
    var refreshing: Bool { monthlyRefreshing || grokRefreshing || tokenLoading }
    @Published var displayMode: DisplayMode { didSet { defaults.set(displayMode.rawValue, forKey: "displayMode"); onDisplayChange?() } }
    @Published var showGrok: Bool {
        didSet {
            defaults.set(showGrok, forKey: "showGrok")
            if oldValue != showGrok {
                if showGrok { refresh() }
                else { cancelGrok(); grok = nil; grokError = nil }
            }
            onDisplayChange?()
        }
    }
    @Published var workdaysOnly: Bool { didSet { defaults.set(workdaysOnly, forKey: "workdaysOnly") } }
    /// Morning baselines per quota id (`C`, `O`, `G`). Persisted so the daily
    /// budget survives restarts and stays fixed until the next morning.
    @Published var dailyAnchors: [String: DailyAnchor] = [:]
    var onDisplayChange: (() -> Void)?
    private let defaults: UserDefaults
    private var generation = 0
    private var grokGeneration = 0
    private var monthlyTask: Task<Void, Never>?
    private var grokTask: Task<Void, Never>?
    private var tokenTask: Task<Void, Never>?
    private var lastToken: String?
    private var consecutiveFailures = 0
    private var backoffUntil: Date?
    private let demo: Bool
    private let tokenLoader: () async throws -> String
    private let monthlyLoader: (String) async throws -> [Quota]
    private let grokLoader: (String) async throws -> Quota

    init(demo: Bool = false, defaults: UserDefaults? = nil,
         tokenLoader: @escaping () async throws -> String = { try await Authentication.automaticToken() },
         monthlyLoader: @escaping (String) async throws -> [Quota] = { try UsageParser.monthly(await CursorAPI.fetch("GetCurrentPeriodUsage", token: $0)) },
         grokLoader: @escaping (String) async throws -> Quota = { try UsageParser.grok(await CursorAPI.fetch("GetSandUsageStatus", token: $0)) }) {
        self.demo = demo
        self.defaults = defaults ?? (demo ? UserDefaults(suiteName: "dev.fraussen.cadence.preview")! : .standard)
        self.tokenLoader = tokenLoader
        self.monthlyLoader = monthlyLoader
        self.grokLoader = grokLoader
        let defaults = self.defaults
        defaults.removeObject(forKey: "authMode")
        defaults.removeObject(forKey: "authSource")
        displayMode = DisplayMode(rawValue: defaults.string(forKey: "displayMode") ?? "both") ?? .both
        showGrok = defaults.object(forKey: "showGrok") as? Bool ?? true
        workdaysOnly = defaults.bool(forKey: "workdaysOnly")
        dailyAnchors = Self.loadDailyAnchors(from: defaults)
        if demo {
            let now = Date()
            monthly = [Quota(id: "C", name: "Cursor Models", used: 12.3, reset: now.addingTimeInterval(25 * 86400), updated: now),
                        Quota(id: "O", name: "Other Models", used: 14, reset: now.addingTimeInterval(25 * 86400), updated: now)]
            grok = Quota(id: "G", name: "Grok Bot", used: 2.3, reset: now.addingTimeInterval(7 * 86400), updated: now)
            recordDailySnapshots(for: monthly + (grok.map { [$0] } ?? []), at: now)
        }
    }

    // MARK: - Daily budget (fixed morning allowance)

    private static func dailyKey(for id: String) -> String { "dailyAnchor.\(id)" }

    private static func loadDailyAnchors(from defaults: UserDefaults) -> [String: DailyAnchor] {
        var result: [String: DailyAnchor] = [:]
        for id in ["C", "O", "G"] {
            guard let data = defaults.data(forKey: dailyKey(for: id)) else { continue }
            guard let anchor = try? JSONDecoder().decode(DailyAnchor.self, from: data) else { continue }
            guard anchor.startUsed.isFinite, anchor.startRemaining.isFinite, anchor.lastUsed.isFinite else { continue }
            result[id] = anchor
        }
        return result
    }

    private func saveDailyAnchor(_ anchor: DailyAnchor, for id: String) {
        dailyAnchors[id] = anchor
        if let data = try? JSONEncoder().encode(anchor) {
            defaults.set(data, forKey: Self.dailyKey(for: id))
        }
    }

    /// Freeze this morning's baseline on first sight each day; keep it steady
    /// afterwards. Called after every successful fetch so overnight spend is
    /// carried into today's baseline and savings/overspend redistribute
    /// tomorrow via the fresh `remaining`.
    func recordDailySnapshots(for quotas: [Quota], at now: Date = Date(), calendar: Calendar = .current) {
        for quota in quotas {
            let next = DailyPacing.nextAnchor(for: quota, now: now, existing: dailyAnchors[quota.id], calendar: calendar)
            // Skip redundant writes so `@Published` doesn't churn the popover.
            if dailyAnchors[quota.id] != next {
                saveDailyAnchor(next, for: quota.id)
            }
        }
    }

    /// Today's spend vs. this morning's fixed budget. Percentages are shares
    /// of the total provider quota. Falls back to a live `remaining/days`
    /// estimate before the first snapshot so the card never shows `—`
    /// unnecessarily.
    func dailyInfo(for quota: Quota, at now: Date = Date(), workdaysOnly: Bool? = nil, calendar: Calendar = .current) -> DailyBudgetInfo {
        quota.dailyInfo(at: now, anchor: dailyAnchors[quota.id],
                        workdaysOnly: workdaysOnly ?? self.workdaysOnly, calendar: calendar)
    }

    func authenticationChanged() {
        invalidate()
        refresh()
    }

    private func invalidate() {
        generation += 1
        tokenTask?.cancel(); tokenTask = nil
        tokenLoading = false
        monthlyTask?.cancel(); monthlyTask = nil
        monthlyRefreshing = false
        cancelGrok()
        monthly = []; grok = nil; monthlyError = nil; grokError = nil
        lastToken = nil
    }

    private func cancelGrok() {
        grokGeneration += 1
        grokTask?.cancel(); grokTask = nil
        grokRefreshing = false
    }

    /// Manual refresh. Always runs; used by popover open, Retry, and auth changes.
    func refresh() {
        guard !demo else {
            recordDailySnapshots(for: monthly + (grok.map { [$0] } ?? []))
            onDisplayChange?()
            return
        }
        // Debounce concurrent token loads; fetch tasks debounce individually below.
        guard tokenTask == nil else { onDisplayChange?(); return }
        tokenLoading = true
        onDisplayChange?()
        let current = generation
        tokenTask = Task {
            let tokenResult: Result<String, Error>
            do { tokenResult = .success(try await tokenLoader()) }
            catch { tokenResult = .failure(error) }
            guard generation == current, !Task.isCancelled else { return }
            tokenTask = nil
            tokenLoading = false
            switch tokenResult {
            case .success(let token):
                // Never show a previous account's balance after Cursor switches accounts.
                if lastToken != token { invalidateAfterToken(current: current); lastToken = token }
                else { lastToken = token }
                startFetches(token: token, generation: generation)
            case .failure(let error):
                invalidateAfterToken(current: current)
                monthlyError = error.localizedDescription; grokError = error.localizedDescription
                noteCycleFinished()
            }
            onDisplayChange?()
        }
    }

    /// Automatic refresh for the 60s timer. Skips while in exponential backoff
    /// so an offline or failing backend does not hammer the API.
    func refreshIfDue(at now: Date = Date()) {
        if let until = backoffUntil, now < until { updateMenuBarOnly(); return }
        refresh()
    }

    private func updateMenuBarOnly() { onDisplayChange?() }

    private func invalidateAfterToken(current: Int) {
        // Token changed or failed: drop stale balances without cancelling the
        // just-finished token task (already nil) but cancel in-flight fetches
        // from the previous account.
        _ = current
        generation += 1
        monthlyTask?.cancel(); monthlyTask = nil
        monthlyRefreshing = false
        cancelGrok()
        monthly = []; grok = nil; monthlyError = nil; grokError = nil
        lastToken = nil
    }

    private func startFetches(token: String, generation current: Int) {
        if !monthlyRefreshing {
            monthlyRefreshing = true
            monthlyTask = Task {
                let result = await fetchMonthly(token)
                guard generation == current else { return }
                switch result {
                case .success(let quotas):
                    monthly = quotas; monthlyError = nil
                    recordDailySnapshots(for: quotas)
                case .failure(let error): monthlyError = error.localizedDescription
                }
                monthlyRefreshing = false; monthlyTask = nil
                noteCycleFinished()
                onDisplayChange?()
            }
        }
        if showGrok && !grokRefreshing {
            grokRefreshing = true
            let request = grokGeneration
            grokTask = Task {
                let result = await fetchGrok(token)
                guard generation == current, grokGeneration == request else { return }
                switch result {
                case .success(let quota):
                    grok = quota; grokError = nil
                    recordDailySnapshots(for: [quota])
                case .failure(let error): grokError = error.localizedDescription
                }
                grokRefreshing = false; grokTask = nil
                noteCycleFinished()
                onDisplayChange?()
            }
        }
        // Token-only refresh with nothing to fetch (hidden Grok, monthly already
        // refreshing) still needs a display update; cycle accounting happens on
        // pool completion.
        onDisplayChange?()
    }

    private func noteCycleFinished() {
        // Evaluate once the cycle is idle. Full success clears backoff;
        // any visible error schedules exponential backoff (60s, 120s, 240s… cap 15m).
        guard tokenTask == nil, !monthlyRefreshing, !grokRefreshing else { return }
        let hasError = monthlyError != nil || (showGrok && grokError != nil)
        // No data and no error (e.g. hidden Grok, nothing started) is not a failure.
        let hasData = !monthly.isEmpty || (showGrok && grok != nil)
        if hasError {
            consecutiveFailures += 1
            let delay = min(900.0, 60.0 * pow(2.0, Double(max(0, consecutiveFailures - 1))))
            backoffUntil = Date().addingTimeInterval(delay)
        } else if hasData {
            consecutiveFailures = 0
            backoffUntil = nil
        }
    }

    private func fetchMonthly(_ token: String) async -> Result<[Quota], Error> {
        do { return .success(try await monthlyLoader(token)) }
        catch { return .failure(error) }
    }
    private func fetchGrok(_ token: String) async -> Result<Quota, Error> {
        do { return .success(try await grokLoader(token)) }
        catch { return .failure(error) }
    }

    enum SyncStatus: String {
        case demo = "Demo data — not connected"
        case fetching = "Refreshing from Cursor…"
        case unavailable = "Sync unavailable — open Cursor and retry"
        case stale = "Usage is stale — retry to update"
        case connected = "Connected to Cursor desktop app"
        case idle = "Waiting to sync with Cursor"
    }

    func syncStatus(at now: Date = Date()) -> SyncStatus {
        if demo { return .demo }
        if refreshing { return .fetching }
        if monthlyError != nil || (showGrok && grokError != nil) { return .unavailable }
        if monthly.contains(where: { $0.isStale(at: now) }) || (showGrok && grok?.isStale(at: now) == true) { return .stale }
        if monthly.isEmpty || (showGrok && grok == nil) { return .idle }
        return .connected
    }

    var lastSuccess: Date? {
        (monthly.map(\.updated) + (showGrok ? [grok?.updated].compactMap { $0 } : [])).max()
    }

    var toolbarTitle: String {
        var pieces = ["C", "O"].map { id in
            monthly.first(where: { $0.id == id }).map { String(format: "%@ %.0f%%", id, $0.remaining) } ?? "\(id) —"
        }
        if showGrok { pieces.append(grok.map { String(format: "G %.0f%%", $0.remaining) } ?? "G —") }
        return pieces.joined(separator: " · ") + (hasProblem ? " !" : "")
    }
    var hasProblem: Bool {
        monthlyError != nil || monthly.contains(where: { $0.isStale() }) ||
        (showGrok && (grokError != nil || grok?.isStale() == true))
    }
}
