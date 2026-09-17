import Foundation

enum UsageError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

struct Quota: Identifiable {
    let id: String
    let name: String
    let used: Double
    let reset: Date
    let updated: Date
    var remaining: Double { max(0, 100 - used) }
    func isStale(at now: Date = Date()) -> Bool { reset <= now || now.timeIntervalSince(updated) > 180 }

    func daysLeft(at now: Date = Date(), workdaysOnly: Bool = false, calendar: Calendar = .current) -> Int {
        guard reset > now else { return 0 }
        let start = calendar.startOfDay(for: now)
        guard start < reset else { return 0 }
        let resetStart = calendar.startOfDay(for: reset)
        guard let diff = calendar.dateComponents([.day], from: start, to: resetStart).day, diff >= 0 else { return 0 }
        // Count each local date overlapping [now, reset), including partial days.
        // A reset exactly at midnight excludes that date; any later reset includes it.
        let total = diff + (reset > resetStart ? 1 : 0)
        guard total > 0 else { return 0 }
        if !workdaysOnly { return total }
        // O(1) weekday count that is correct for any locale weekend definition.
        // Any 7 consecutive dates contain the same multiset of weekdays, so sample
        // the first week once (<=7 date calculations) instead of looping to reset.
        // This also bounds work for absurd far-future resets that pass validation.
        if total <= 14 {
            var count = 0
            for offset in 0..<total {
                guard let date = calendar.date(byAdding: .day, value: offset, to: start) else { continue }
                if !calendar.isDateInWeekend(date) { count += 1 }
            }
            return count
        }
        var weekPattern: [Bool] = []
        weekPattern.reserveCapacity(7)
        for offset in 0..<7 {
            guard let date = calendar.date(byAdding: .day, value: offset, to: start) else { continue }
            weekPattern.append(!calendar.isDateInWeekend(date))
        }
        guard !weekPattern.isEmpty else { return 0 }
        let fullWeeks = total / weekPattern.count
        let remainder = total % weekPattern.count
        let perWeek = weekPattern.filter { $0 }.count
        var count = fullWeeks * perWeek
        for i in 0..<remainder { if weekPattern[i] { count += 1 } }
        return count
    }

    func safePerDay(at now: Date = Date(), workdaysOnly: Bool = false, calendar: Calendar = .current) -> Double? {
        let days = daysLeft(at: now, workdaysOnly: workdaysOnly, calendar: calendar)
        return days > 0 ? remaining / Double(days) : nil
    }

    /// Today's spend as a share of the *total* provider quota.
    /// `anchor` holds this morning's baseline (see `DailyPacing`). Clamped at
    /// zero so server corrections never show negative spend.
    func usedToday(at now: Date = Date(), anchor: DailyAnchor?, calendar: Calendar = .current) -> Double {
        _ = now; _ = calendar
        guard let anchor else { return 0 }
        return max(0, used - anchor.startUsed)
    }

    /// Fixed morning budget as a share of the *total* provider quota.
    /// `anchor.startRemaining` is the morning balance; the divisor is the
    /// number of days/weekdays remaining *that morning*, so the result stays
    /// steady across refreshes while today's spend grows. Returns nil when no
    /// days remain (e.g. weekend-only pacing with no weekdays left).
    func dailyBudget(at now: Date = Date(), anchor: DailyAnchor?, workdaysOnly: Bool = false, calendar: Calendar = .current) -> Double? {
        guard let anchor else { return safePerDay(at: now, workdaysOnly: workdaysOnly, calendar: calendar) }
        let morning = calendar.startOfDay(for: now)
        let probe = Quota(id: id, name: name, used: 100 - anchor.startRemaining, reset: reset, updated: morning)
        let days = probe.daysLeft(at: morning, workdaysOnly: workdaysOnly, calendar: calendar)
        guard days > 0 else { return nil }
        return anchor.startRemaining / Double(days)
    }

    func dailyInfo(at now: Date = Date(), anchor: DailyAnchor?, workdaysOnly: Bool = false, calendar: Calendar = .current) -> DailyBudgetInfo {
        let budget = dailyBudget(at: now, anchor: anchor, workdaysOnly: workdaysOnly, calendar: calendar)
        let used = usedToday(at: now, anchor: anchor, calendar: calendar)
        return DailyBudgetInfo(budget: budget, usedToday: used)
    }

    func resetRemainingText(at now: Date = Date(), workdaysOnly: Bool = false, calendar: Calendar = .current) -> String {
        guard reset > now else {
            let unit = workdaysOnly ? "weekdays left" : "days left"
            return "0 \(unit)"
        }
        if calendar.isDate(now, inSameDayAs: reset) {
            let diff = reset.timeIntervalSince(now)
            if diff < 60 {
                return "< 1 minute left"
            }
            let totalMinutes = Int(ceil(diff / 60.0))
            let hours = totalMinutes / 60
            let minutes = totalMinutes % 60
            if hours > 0 && minutes > 0 {
                let hUnit = hours == 1 ? "hour" : "hours"
                let mUnit = minutes == 1 ? "minute" : "minutes"
                return "\(hours) \(hUnit) and \(minutes) \(mUnit) left"
            } else if hours > 0 {
                let hUnit = hours == 1 ? "hour" : "hours"
                return "\(hours) \(hUnit) left"
            } else {
                let mUnit = totalMinutes == 1 ? "minute" : "minutes"
                return "\(totalMinutes) \(mUnit) left"
            }
        }
        let days = daysLeft(at: now, workdaysOnly: workdaysOnly, calendar: calendar)
        let unit = workdaysOnly
            ? (days == 1 ? "weekday left" : "weekdays left")
            : (days == 1 ? "day left" : "days left")
        return "\(days) \(unit)"
    }
}

/// Morning baseline for one quota pool. `day`/`lastDay` are local
/// `yyyy-MM-dd` strings. `startUsed`/`startRemaining` are frozen at the first
/// observation each morning so the daily budget stays steady all day;
/// `lastUsed`/`lastDay` track the most recent observation to carry overnight
/// spend into the next morning's baseline. `reset` detects a new billing
/// cycle so a fresh balance never inherits yesterday's baseline.
struct DailyAnchor: Codable, Equatable {
    var day: String
    var startUsed: Double
    var startRemaining: Double
    var reset: Date
    var lastUsed: Double
    var lastDay: String
}

/// Today's spend vs. this morning's fixed budget. All percentages are shares
/// of the *total* provider quota (not of the budget), so `budget`,
/// `usedToday`, `available`, and `overBy` are directly comparable.
struct DailyBudgetInfo: Equatable {
    /// Fixed allowance for today (`nil` when no days/weekdays remain).
    let budget: Double?
    /// Amount of the total quota consumed since this morning.
    let usedToday: Double
    /// Near-budget threshold: amber at 80% of the daily allowance.
    static let warningThreshold = 0.8

    var available: Double? { budget.map { $0 - usedToday } }
    var overBy: Double? {
        guard let budget else { return nil }
        return usedToday > budget ? usedToday - budget : nil
    }
    /// 0…1+ progress of today's spend against the budget. Capped by callers
    /// for bar width; values > 1 mean over budget.
    var fraction: Double? {
        guard let budget else { return nil }
        guard budget > 0 else { return usedToday > 0 ? 1 : 0 }
        return usedToday / budget
    }
    var isOver: Bool { overBy != nil }
    var isWarning: Bool {
        guard let fraction, !isOver else { return false }
        // Epsilon so binary floating-point (e.g. 2.8/3.5) doesn't flicker
        // just below the threshold.
        return fraction + 1e-9 >= Self.warningThreshold
    }
}

enum DailyPacing {
    /// Local calendar day key, e.g. `2026-09-17`. Built from components so it
    /// respects the caller's calendar/timezone (important for tests).
    static func dayKey(for date: Date, calendar: Calendar = .current) -> String {
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
    }

    /// Resolve the anchor to persist after observing `quota` at `now`.
    /// - Same day: keep the morning baseline, refresh `lastUsed`.
    /// - New day: baseline is the last observed usage so overnight spend
    ///   counts toward today; the morning balance is `100 - baseline` so the
    ///   new budget reflects pre-spend quota. Savings/overspend therefore
    ///   redistribute tomorrow via the fresh `remaining`.
    /// - New cycle (reset changed) or first run: start fresh with zero spend.
    /// - Downward server corrections (used < baseline) clamp to zero spend
    ///   rather than showing negative usage.
    static func nextAnchor(for quota: Quota, now: Date = Date(), existing: DailyAnchor?, calendar: Calendar = .current) -> DailyAnchor {
        let today = dayKey(for: now, calendar: calendar)
        guard let existing else {
            return DailyAnchor(day: today, startUsed: quota.used, startRemaining: quota.remaining,
                               reset: quota.reset, lastUsed: quota.used, lastDay: today)
        }
        let sameCycle = abs(existing.reset.timeIntervalSince(quota.reset)) < 1
        guard sameCycle else {
            return DailyAnchor(day: today, startUsed: quota.used, startRemaining: quota.remaining,
                               reset: quota.reset, lastUsed: quota.used, lastDay: today)
        }
        if existing.day == today {
            var updated = existing
            if quota.used < existing.startUsed {
                updated.startUsed = quota.used
            }
            updated.lastUsed = quota.used
            updated.lastDay = today
            return updated
        }
        // New day in the same cycle.
        let baseline = existing.lastDay.isEmpty ? quota.used : min(existing.lastUsed, quota.used)
        let morningRemaining = max(0, 100 - baseline)
        return DailyAnchor(day: today, startUsed: baseline, startRemaining: morningRemaining,
                           reset: quota.reset, lastUsed: quota.used, lastDay: today)
    }
}

enum UsageParser {
    static func object(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageError.message("Cursor returned an unrecognized response.")
        }
        return object
    }

    static func percent(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let result = number.doubleValue
        return result.isFinite && result >= 0 ? result : nil
    }

    static func monthly(_ data: Data, now: Date = Date()) throws -> [Quota] {
        let root = try object(data)
        guard let plan = root["planUsage"] as? [String: Any],
              let cursor = percent(plan["autoPercentUsed"]),
              let other = percent(plan["apiPercentUsed"]),
              let ms = milliseconds(root["billingCycleEnd"]),
              ms.isFinite, ms > 0, ms < 32_503_680_000_000 else {
            throw UsageError.message("Monthly quota data is unavailable for this account.")
        }
        let reset = Date(timeIntervalSince1970: ms / 1000)
        // Sanity-bound far-future resets: a monthly cycle beyond a year suggests
        // malformed server data. Reject instead of showing a misleading tiny allowance.
        guard reset.timeIntervalSince(now) <= 366 * 86400 else {
            throw UsageError.message("Monthly quota data is unavailable for this account.")
        }
        return [Quota(id: "C", name: "Cursor Models", used: cursor, reset: reset, updated: now),
                Quota(id: "O", name: "Other Models", used: other, reset: reset, updated: now)]
    }

    static func grok(_ data: Data, now: Date = Date()) throws -> Quota {
        let root = try object(data)
        if root["includedLimitZero"] as? Bool == true {
            throw UsageError.message("No included Grok Bot allowance on this account.")
        }
        guard let used = percent(root["usagePercent"]), let raw = root["nextResetTimestampUtc"] as? String else {
            throw UsageError.message("Grok Bot quota data is unavailable for this account.")
        }
        // Function-local formatters: ISO8601DateFormatter is not Sendable, so no
        // shared static instance. Parses run at most a few times per minute.
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        let reset = fractional.date(from: raw) ?? plain.date(from: raw)
        guard let reset else { throw UsageError.message("Grok Bot reset date is unavailable.") }
        // Weekly pool should reset within weeks, not months. Bound absurd dates.
        guard reset.timeIntervalSince(now) <= 93 * 86400 else {
            throw UsageError.message("Grok Bot quota data is unavailable for this account.")
        }
        return Quota(id: "G", name: "Grok Bot", used: used, reset: reset, updated: now)
    }

    private static func milliseconds(_ value: Any?) -> Double? {
        if let number = value as? NSNumber {
            return CFGetTypeID(number) == CFBooleanGetTypeID() ? nil : number.doubleValue
        }
        if let string = value as? String { return Double(string) }
        return nil
    }
}

import CoreFoundation

/// Rejects HTTP redirects so the `Authorization: Bearer` token is never
/// forwarded to another origin. The Cursor API is not expected to redirect;
/// a 3xx surfaces as an API error instead.
private final class CursorAPIRedirectGuard: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum CursorAPI {
    private static let redirectGuard = CursorAPIRedirectGuard()
    // Shared ephemeral session: no disk cache, connection reuse across the
    // 60s refresh cadence instead of a fresh TLS handshake per request.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 20
        return URLSession(configuration: config, delegate: redirectGuard, delegateQueue: nil)
    }()

    static func fetch(_ method: String, token: String) async throws -> Data {
        guard method.allSatisfy({ $0.isLetter || $0.isNumber }),
              let url = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/\(method)") else {
            throw UsageError.message("Cursor returned an unrecognized response.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.httpBody = Data("{}".utf8)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue("Cadence (macOS menu bar)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw UsageError.message("No response from Cursor.") }
        guard response.statusCode == 200 else {
            throw UsageError.message(response.statusCode == 401 || response.statusCode == 403
                ? "Session rejected. Sign in to the Cursor desktop app again, then retry."
                : "Cursor API error (HTTP \(response.statusCode)). Try refreshing later.")
        }
        return data
    }
}
