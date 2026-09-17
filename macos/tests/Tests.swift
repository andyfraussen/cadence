import Foundation
import SQLite3

@main
struct Tests {
    static func main() async throws {
        var assertions = 0
        func check(_ condition: @autoclosure () -> Bool, _ name: String) {
            precondition(condition(), name)
            assertions += 1
        }
        func rejects(_ json: String, grok: Bool = false) {
            do {
                if grok { _ = try UsageParser.grok(Data(json.utf8)) }
                else { _ = try UsageParser.monthly(Data(json.utf8)) }
                preconditionFailure("Invalid quota was accepted")
            } catch { assertions += 1 }
        }
        let now = ISO8601DateFormatter().date(from: "2026-09-10T12:00:00Z")!
        let iso = ISO8601DateFormatter()
        for (start, end, zone, weekdays, days) in [
            ("2026-09-13T12:00:00Z", "2026-09-14T12:00:00Z", "UTC", 1, 2),
            ("2026-11-01T00:00:00-07:00", "2026-11-02T00:00:00-08:00", "America/Los_Angeles", 0, 1),
            ("2026-03-08T00:00:00-08:00", "2026-03-09T00:00:00-07:00", "America/Los_Angeles", 0, 1),
            ("2026-09-11T23:59:00Z", "2026-09-14T00:00:00Z", "UTC", 1, 3),
            ("2026-09-14T01:00:00Z", "2026-09-14T12:00:00Z", "UTC", 1, 1)
        ] {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: zone)!
            let start = iso.date(from: start)!
            let quota = Quota(id: "C", name: "Calendar", used: 50, reset: iso.date(from: end)!, updated: start)
            check(quota.daysLeft(at: start, workdaysOnly: true, calendar: calendar) == weekdays, "Weekday overlap: \(end)")
            check(quota.daysLeft(at: start, calendar: calendar) == days, "Calendar overlap: \(end)")
        }
        for timestamp in ["true", "false", "null", "\"Infinity\"", "\"1e309\"", "32503680000000", "0", "-1"] {
            rejects("{\"billingCycleEnd\":\(timestamp),\"planUsage\":{\"autoPercentUsed\":0,\"apiPercentUsed\":0}}")
        }
        let monthly = try UsageParser.monthly(Data("""
        {"billingCycleEnd":"1791114713000","planUsage":{"autoPercentUsed":12.25,"apiPercentUsed":14}}
        """.utf8), now: now)
        check(monthly.count == 2, "Two monthly pools")
        check(monthly[0].remaining == 87.75, "Remaining percentage")
        check(monthly[1].remaining == 86, "Other models independently parsed")
        check(monthly[0].reset.timeIntervalSince1970 == 1791114713, "Milliseconds decoded")
        check(!monthly[0].isStale(at: now), "Fresh response")
        check(monthly[0].isStale(at: now.addingTimeInterval(181)), "Old response is stale")
        let zero = try UsageParser.monthly(Data("""
        {"billingCycleEnd":1791114713000,"planUsage":{"autoPercentUsed":0,"apiPercentUsed":125}}
        """.utf8))
        check(zero[0].remaining == 100, "Explicit zero is valid")
        check(zero[1].remaining == 0, "Over quota never becomes negative")
        rejects("{}")
        rejects("[]")
        rejects("{\"billingCycleEnd\":1791114713000,\"planUsage\":{\"autoPercentUsed\":0}}")
        rejects("{\"billingCycleEnd\":\"NaN\",\"planUsage\":{\"autoPercentUsed\":0,\"apiPercentUsed\":0}}")
        rejects("{\"billingCycleEnd\":1791114713000,\"planUsage\":{\"autoPercentUsed\":true,\"apiPercentUsed\":0}}")
        rejects("{\"billingCycleEnd\":1791114713000,\"planUsage\":{\"autoPercentUsed\":-1,\"apiPercentUsed\":0}}")
        let grok = try UsageParser.grok(Data("""
        {"usagePercent":2.250393,"nextResetTimestampUtc":"2026-09-16T18:40:25.160Z","hasNonZeroIncludedLimit":true}
        """.utf8), now: now)
        check(abs(grok.remaining - 97.749607) < 0.000001, "Grok percentages are not fractions")
        check(grok.reset != monthly[0].reset, "Grok has its own reset")
        let grokZero = try UsageParser.grok(Data("""
        {"usagePercent":0,"nextResetTimestampUtc":"2026-09-16T18:40:25Z"}
        """.utf8))
        check(grokZero.remaining == 100, "Whole-second Grok timestamp and zero usage")
        rejects("{}", grok: true)
        rejects("{\"usagePercent\":0,\"includedLimitZero\":true,\"nextResetTimestampUtc\":\"2026-09-16T18:40:25Z\"}", grok: true)
        rejects("{\"usagePercent\":0,\"nextResetTimestampUtc\":\"bad date\"}", grok: true)
        let example = Quota(id: "C", name: "Example", used: 20, reset: now.addingTimeInterval(20 * 86400), updated: now)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        check(example.safePerDay(at: now, calendar: calendar) == 80.0 / 21, "Noon-to-noon across 20 elapsed days overlaps 21 dates")
        let midnight = calendar.startOfDay(for: now)
        let fullDays = Quota(id: "C", name: "Full days", used: 20, reset: midnight.addingTimeInterval(20 * 86400), updated: midnight)
        check(fullDays.safePerDay(at: midnight, calendar: calendar) == 4, "80% left / 20 whole calendar days = 4 percentage points per day")
        check(example.safePerDay(at: example.reset) == nil, "No pacing after reset")
        check(example.isStale(at: example.reset), "Reset invalidates old data")
        let saturday = ISO8601DateFormatter().date(from: "2026-09-12T12:00:00Z")!
        let weekend = Quota(id: "G", name: "Weekend", used: 50, reset: saturday.addingTimeInterval(86400), updated: saturday)
        check(weekend.safePerDay(at: saturday, workdaysOnly: true, calendar: calendar) == nil, "Zero weekdays is unavailable, not an invented allowance")
        let week = Quota(id: "G", name: "Week", used: 50, reset: now.addingTimeInterval(7 * 86400), updated: now)
        check(week.daysLeft(at: now, workdaysOnly: true, calendar: calendar) == 6, "Noon-to-noon week includes both partial Thursdays")
        check(week.safePerDay(at: now, workdaysOnly: true, calendar: calendar) == 50.0 / 6, "Partial-weekday pacing")
        let fullWeek = Quota(id: "C", name: "Full week", used: 50, reset: midnight.addingTimeInterval(7 * 86400), updated: midnight)
        check(fullWeek.daysLeft(at: midnight, workdaysOnly: true, calendar: calendar) == 5, "Five weekdays in a midnight-to-midnight week")
        // Far-future resets are rejected as malformed instead of producing tiny allowances.
        let farMonthlyMs = Int64((now.timeIntervalSince1970 + 400 * 86400) * 1000)
        rejects("{\"billingCycleEnd\":\(farMonthlyMs),\"planUsage\":{\"autoPercentUsed\":10,\"apiPercentUsed\":10}}")
        let farGrokDate = ISO8601DateFormatter().string(from: now.addingTimeInterval(100 * 86400))
        rejects("{\"usagePercent\":10,\"nextResetTimestampUtc\":\"\(farGrokDate)\"}", grok: true)
        // O(1) long-range pacing: 400-day window completes without looping to reset.
        let longReset = now.addingTimeInterval(400 * 86400)
        let longQuota = Quota(id: "C", name: "Long", used: 50, reset: longReset, updated: now)
        let longDays = longQuota.daysLeft(at: now, calendar: calendar)
        check(longDays > 390 && longDays <= 402, "Long-range calendar count is bounded and sane")
        let longWeekdays = longQuota.daysLeft(at: now, workdaysOnly: true, calendar: calendar)
        check(longWeekdays > 0 && longWeekdays < longDays, "Long-range weekday count is a proper subset")
        // Token cleaning: trim whitespace and unwrap JSON-quoted storage values.
        check((try? Authentication.cleanToken("  abc123  ")) == "abc123", "Token whitespace is trimmed")
        check((try? Authentication.cleanToken("\"abc123\"")) == "abc123", "JSON-quoted token is unwrapped")
        do { _ = try Authentication.cleanToken("   "); preconditionFailure("Blank token was accepted") } catch { assertions += 1 }
        do { _ = try Authentication.cleanToken("\"\""); preconditionFailure("Empty quoted token was accepted") } catch { assertions += 1 }
        // Remaining time formatting: same-day hours/minutes and multi-day pluralization
        let sameDayQuota = Quota(id: "G", name: "Grok", used: 63.1, reset: now.addingTimeInterval(4 * 3600 + 33 * 60 + 15), updated: now)
        check(sameDayQuota.resetRemainingText(at: now, calendar: calendar) == "4 hours and 34 minutes left", "Same-day hours and minutes")
        check(sameDayQuota.resetRemainingText(at: now, workdaysOnly: true, calendar: calendar) == "4 hours and 34 minutes left", "Same-day respects hour format with workdaysOnly")

        let exactHourQuota = Quota(id: "G", name: "Grok", used: 10, reset: now.addingTimeInterval(2 * 3600), updated: now)
        check(exactHourQuota.resetRemainingText(at: now, calendar: calendar) == "2 hours left", "Exact hours plural")

        let oneHourQuota = Quota(id: "G", name: "Grok", used: 10, reset: now.addingTimeInterval(3600), updated: now)
        check(oneHourQuota.resetRemainingText(at: now, calendar: calendar) == "1 hour left", "Exact 1 hour singular")

        let oneHourOneMinQuota = Quota(id: "G", name: "Grok", used: 10, reset: now.addingTimeInterval(3660), updated: now)
        check(oneHourOneMinQuota.resetRemainingText(at: now, calendar: calendar) == "1 hour and 1 minute left", "1 hour and 1 minute singulars")

        let minutesQuota = Quota(id: "G", name: "Grok", used: 10, reset: now.addingTimeInterval(34 * 60), updated: now)
        check(minutesQuota.resetRemainingText(at: now, calendar: calendar) == "34 minutes left", "Minutes only plural")

        let oneMinQuota = Quota(id: "G", name: "Grok", used: 10, reset: now.addingTimeInterval(60), updated: now)
        check(oneMinQuota.resetRemainingText(at: now, calendar: calendar) == "1 minute left", "1 minute singular")

        let subMinuteQuota = Quota(id: "G", name: "Grok", used: 10, reset: now.addingTimeInterval(15), updated: now)
        check(subMinuteQuota.resetRemainingText(at: now, calendar: calendar) == "< 1 minute left", "Under one minute left")

        let pastQuota = Quota(id: "G", name: "Grok", used: 10, reset: now.addingTimeInterval(-10), updated: now)
        check(pastQuota.resetRemainingText(at: now, calendar: calendar) == "0 days left", "Past reset returns 0 days left")
        check(pastQuota.resetRemainingText(at: now, workdaysOnly: true, calendar: calendar) == "0 weekdays left", "Past reset returns 0 weekdays left")

        let tomorrowMidnight = midnight.addingTimeInterval(86400)
        let oneDayQuota = Quota(id: "C", name: "Cursor", used: 10, reset: tomorrowMidnight, updated: now)
        check(oneDayQuota.resetRemainingText(at: now, calendar: calendar) == "1 day left", "1 day singular")
        check(fullDays.resetRemainingText(at: midnight, calendar: calendar) == "20 days left", "Multi-day plural")
        check(fullWeek.resetRemainingText(at: midnight, workdaysOnly: true, calendar: calendar) == "5 weekdays left", "Multi-weekday plural")

        try checkSQLiteFixture()
        print("Passed \(assertions) parser and pacing checks.")
        if CommandLine.arguments.contains("--live") {
            let token = try await Authentication.automaticToken()
            let liveMonthly = try UsageParser.monthly(await CursorAPI.fetch("GetCurrentPeriodUsage", token: token))
            let liveGrok = try UsageParser.grok(await CursorAPI.fetch("GetSandUsageStatus", token: token))
            for quota in liveMonthly + [liveGrok] {
                print(String(format: "%@: %.2f%% left; %.2f%% safe per day", quota.name, quota.remaining, quota.safePerDay() ?? 0))
            }
            print("Live Swift API checks passed. No credentials printed or persisted.")
        }
    }

    /// Temporary SQLite fixture: verifies readToken against a real database file
    /// without touching the user's Cursor install.
    static func checkSQLiteFixture() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("cadence-test-\(UUID().uuidString).vscdb").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        var db: OpaquePointer?
        precondition(sqlite3_open(path, &db) == SQLITE_OK, "Fixture database opens")
        defer { sqlite3_close(db) }
        precondition(sqlite3_exec(db, "CREATE TABLE ItemTable(key TEXT PRIMARY KEY, value TEXT)", nil, nil, nil) == SQLITE_OK, "Fixture table creates")
        precondition(sqlite3_exec(db, "INSERT INTO ItemTable(key, value) VALUES('cursorAuth/accessToken', '\"fixture-token-123\"')", nil, nil, nil) == SQLITE_OK, "Fixture token inserts")
        let token = try Authentication.readToken(at: path)
        precondition(token == "fixture-token-123", "JSON-quoted fixture token is unwrapped")
        do {
            _ = try Authentication.readToken(at: path + ".missing")
            preconditionFailure("Missing database was accepted")
        } catch { }
    }
}
