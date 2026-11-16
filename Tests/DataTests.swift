import Foundation

private func decode(_ json: String) -> Usage? {
    try? JSONDecoder().decode(Usage.self, from: Data(json.utf8))
}

func testDecoding() {
    suite("Decoding: normal payload") {
        let u = decode("""
        {"five_hour": {"utilization": 11.0, "resets_at": "2026-11-16T15:00:00.123+00:00"},
         "seven_day": {"utilization": 24, "resets_at": "2026-11-20T09:00:00+00:00"},
         "limits": [{"kind": "weekly_scoped", "percent": 30, "resets_at": "2026-11-20T09:00:00+00:00",
                     "scope": {"model": {"display_name": "Fable"}}}],
         "seven_day_breakdown": {"rows": [{"display_name": "Claude Code", "percent": 80}]}}
        """)
        expectClose(u?.five_hour?.utilization, 11)
        expectClose(u?.seven_day?.utilization, 24)
        expect(parseDate(u?.five_hour?.resets_at) != nil, "fractional seconds parse")
        expect(parseDate(u?.seven_day?.resets_at) != nil, "whole seconds parse")
        expectEqual(u?.limits?.first?.kind, "weekly_scoped")
        expectEqual(u?.limits?.first?.scope?.model?.display_name, "Fable")
        expectEqual(u?.seven_day_breakdown?.rows?.count, 1)
    }

    suite("Decoding: unknown and malformed limits entries") {
        let u = decode("""
        {"five_hour": {"utilization": 5},
         "limits": [{"kind": "something_new", "extra": {"nested": [1, 2]}},
                    "not an object",
                    {"percent": 12},
                    {"kind": "weekly_scoped", "percent": "oops"}]}
        """)
        expectClose(u?.five_hour?.utilization, 5)
        expectEqual(u?.limits?.count, 3, "the string entry is skipped, the rest kept")
        expectEqual(u?.limits?.first?.kind, "something_new")
        expect(u?.limits?[1].kind == nil, "missing kind is fine")
        expect(u?.limits?[2].percent == nil, "wrong-typed field reads as missing")
    }

    suite("Decoding: five_hour missing, wrong types, empty") {
        let u = decode("""
        {"seven_day": {"utilization": 40, "resets_at": null}, "five_hour": "nope"}
        """)
        expect(u != nil)
        expect(u?.five_hour == nil, "wrong-typed window reads as missing")
        expectClose(u?.seven_day?.utilization, 40)
        let empty = decode("{}")
        expect(empty != nil, "empty object decodes")
        expect(empty?.five_hour == nil && empty?.limits == nil)
        expect(decode("[]") == nil, "not an object at all still fails")
    }
}

func testCredentials() {
    suite("Credentials.parse") {
        let c = Credentials.parse(Data(#"{"claudeAiOauth": {"accessToken": "t1", "expiresAt": 1795000000000}}"#.utf8))
        expectEqual(c?.token, "t1")
        expectClose(c?.expiresAt?.timeIntervalSince1970, 1_795_000_000, "expiresAt is milliseconds")
        let noExpiry = Credentials.parse(Data(#"{"claudeAiOauth": {"accessToken": "t2"}}"#.utf8))
        expect(noExpiry != nil && noExpiry?.expiresAt == nil, "expiry is optional")
        expect(Credentials.parse(Data(#"{"claudeAiOauth": {}}"#.utf8)) == nil, "no token")
        expect(Credentials.parse(Data("garbage".utf8)) == nil)
    }

    suite("Credentials.expiresSoon") {
        let now = Date()
        expect(Credentials(token: "a", expiresAt: now.addingTimeInterval(30)).expiresSoon(now: now))
        expect(Credentials(token: "a", expiresAt: now.addingTimeInterval(-5)).expiresSoon(now: now))
        expect(!Credentials(token: "a", expiresAt: now.addingTimeInterval(3600)).expiresSoon(now: now))
        expect(!Credentials(token: "a", expiresAt: nil).expiresSoon(now: now), "unknown expiry counts as fine")
    }

    suite("Problem messages") {
        let all: [UsageProblem] = [.loginExpired, .loginNotFound, .keychainDenied, .credentialsUnreadable,
                                   .unavailable(status: 500), .badResponse]
        for p in all {
            expect(!p.short.contains("`") && !p.long.contains("`"), "no literal backticks: \(p)")
            expect(p.short.count <= 30, "short form fits a status line: \(p.short)")
        }
        expectEqual(UsageProblem.unavailable(status: 502).long, "Anthropic returned HTTP 502.")
    }
}

func testNotifiedLog() {
    suite("NotifiedLog record / prune") {
        withDefaults { d in
            let now = date(2026, 11, 16)
            NotifiedLog.record(["a", "b"], now: now.addingTimeInterval(-15 * 86400), defaults: d)
            NotifiedLog.record(["c"], now: now, defaults: d)
            expect(NotifiedLog.contains("a", defaults: d))
            NotifiedLog.prune(now: now, defaults: d)
            expect(!NotifiedLog.contains("a", defaults: d), "older than 14 days is pruned")
            expect(NotifiedLog.contains("c", defaults: d))
        }
    }

    suite("NotifiedLog legacy migration") {
        withDefaults { d in
            let now = date(2026, 11, 16, 12)
            let recentWindow = Int(now.addingTimeInterval(3600).timeIntervalSince1970 / 60)
            let oldWindow = Int(now.addingTimeInterval(-60 * 86400).timeIntervalSince1970 / 60)
            d.set(true, forKey: "alert-Session limit-\(recentWindow)-80")
            d.set(true, forKey: "alert-Session limit-\(oldWindow)-95")
            d.set(true, forKey: "sessionReset-\(recentWindow)")
            d.set(true, forKey: "notified-\(Int(now.timeIntervalSince1970) + 86400)-3600")
            d.set([80, 95], forKey: "alertThresholds.session")
            d.set(true, forKey: "alertEnabled.session")

            NotifiedLog.migrateLegacy(now: now, defaults: d)

            let leftover = d.dictionaryRepresentation().keys.filter {
                $0.hasPrefix("alert-") || $0.hasPrefix("sessionReset-") || $0.hasPrefix("notified-")
            }
            expect(leftover.isEmpty, "all legacy keys removed: \(leftover)")
            expect(d.array(forKey: "alertThresholds.session") != nil, "settings untouched")
            expect(d.object(forKey: "alertEnabled.session") != nil, "settings untouched")
            expect(NotifiedLog.contains("alert-Session limit-\(recentWindow)-80", defaults: d),
                   "recent alert carried over so it doesn't fire again")
            expect(NotifiedLog.contains("sessionReset-\(recentWindow)", defaults: d))
            expect(!NotifiedLog.contains("alert-Session limit-\(oldWindow)-95", defaults: d), "old one dropped")
        }
    }
}

func testHourlyLog() {
    suite("HourlyLog keeps 7 days") {
        withDefaults { d in
            let cal = Calendar.current
            let today = cal.startOfDay(for: Date())
            for back in 0..<10 {
                let day = cal.date(byAdding: .day, value: -back, to: today)!
                d.set(Array(repeating: 1.0, count: 24), forKey: HourlyLog.key(day))
            }
            HourlyLog.prune(now: Date(), defaults: d)
            let kept = d.dictionaryRepresentation().keys.filter { $0.hasPrefix(HourlyLog.prefix) }
            expectEqual(kept.count, 7)
            expect(d.object(forKey: HourlyLog.key(today)) != nil, "today kept")
            expect(d.object(forKey: HourlyLog.key(cal.date(byAdding: .day, value: -7, to: today)!)) == nil,
                   "8th day back removed")
        }
    }
}
