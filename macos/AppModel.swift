import AppKit
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var monthly: [Quota] = []
    @Published var grok: Quota?
    @Published var monthlyError: String?
    @Published var grokError: String?
    @Published private(set) var monthlyRefreshing = false
    @Published private(set) var grokRefreshing = false
    var refreshing: Bool { monthlyRefreshing || grokRefreshing }
    @Published var displayMode: String { didSet { defaults.set(displayMode, forKey: "displayMode"); onDisplayChange?() } }
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
    var onDisplayChange: (() -> Void)?
    private let defaults: UserDefaults
    private var generation = 0
    private var grokGeneration = 0
    private var monthlyTask: Task<Void, Never>?
    private var grokTask: Task<Void, Never>?
    private var lastToken: String?
    private let demo: Bool
    private let tokenLoader: () throws -> String
    private let monthlyLoader: (String) async throws -> [Quota]
    private let grokLoader: (String) async throws -> Quota

    init(demo: Bool = false, defaults: UserDefaults? = nil,
         tokenLoader: @escaping () throws -> String = Authentication.automaticToken,
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
        displayMode = defaults.string(forKey: "displayMode") ?? "both"
        showGrok = defaults.object(forKey: "showGrok") as? Bool ?? true
        workdaysOnly = defaults.bool(forKey: "workdaysOnly")
        if demo {
            let now = Date()
            monthly = [Quota(id: "C", name: "Cursor Models", used: 12.3, reset: now.addingTimeInterval(25 * 86400), updated: now),
                       Quota(id: "O", name: "Other Models", used: 14, reset: now.addingTimeInterval(25 * 86400), updated: now)]
            grok = Quota(id: "G", name: "Grok Bot", used: 2.3, reset: now.addingTimeInterval(7 * 86400), updated: now)
        }
    }

    func authenticationChanged() {
        invalidate()
        refresh()
    }

    private func invalidate() {
        generation += 1
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

    func refresh() {
        guard !demo else { onDisplayChange?(); return }
        do {
            let token = try tokenLoader()
            // Never show a previous account's balance after Cursor switches accounts.
            if lastToken != token { invalidate() }
            lastToken = token
            let current = generation
            if !monthlyRefreshing {
                monthlyRefreshing = true
                monthlyTask = Task {
                    let result = await fetchMonthly(token)
                    guard generation == current else { return }
                    switch result {
                    case .success(let quotas): monthly = quotas; monthlyError = nil
                    case .failure(let error): monthlyError = error.localizedDescription
                    }
                    monthlyRefreshing = false; monthlyTask = nil
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
                    case .success(let quota): grok = quota; grokError = nil
                    case .failure(let error): grokError = error.localizedDescription
                    }
                    grokRefreshing = false; grokTask = nil
                    onDisplayChange?()
                }
            }
        } catch {
            invalidate()
            monthlyError = error.localizedDescription; grokError = error.localizedDescription
        }
        onDisplayChange?()
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
