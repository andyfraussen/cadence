import Foundation

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
        print("Passed \(assertions) parser and pacing checks.")
        if CommandLine.arguments.contains("--live") {
            let token = try Authentication.automaticToken()
            let liveMonthly = try UsageParser.monthly(await CursorAPI.fetch("GetCurrentPeriodUsage", token: token))
            let liveGrok = try UsageParser.grok(await CursorAPI.fetch("GetSandUsageStatus", token: token))
            for quota in liveMonthly + [liveGrok] {
                print(String(format: "%@: %.2f%% left; %.2f%% safe per day", quota.name, quota.remaining, quota.safePerDay() ?? 0))
            }
            print("Live Swift API checks passed. No credentials printed or persisted.")
        }
    }
}
