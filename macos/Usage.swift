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
        var day = calendar.startOfDay(for: now)
        var days = 0
        // Count each local date overlapping [now, reset), including partial days.
        while day < reset {
            if !workdaysOnly || !calendar.isDateInWeekend(day) { days += 1 }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day), next > day else { break }
            day = next
        }
        return days
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
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var reset = formatter.date(from: raw)
        if reset == nil { formatter.formatOptions = [.withInternetDateTime]; reset = formatter.date(from: raw) }
        guard let reset else { throw UsageError.message("Grok Bot reset date is unavailable.") }
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

enum CursorAPI {
    static func fetch(_ method: String, token: String) async throws -> Data {
        let url = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/\(method)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.httpBody = Data("{}".utf8)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        // Ephemeral sessions keep credentials and usage responses out of URLCache on disk.
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
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
