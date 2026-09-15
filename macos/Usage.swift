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
