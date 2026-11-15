import Foundation

func testVersions() {
    suite("isNewerVersion ordering") {
        expect(isNewerVersion("0.1.1", than: "0.1.0"))
        expect(isNewerVersion("0.2", than: "0.1.9"))
        expect(isNewerVersion("0.1.10", than: "0.1.9"), "numeric, not string, comparison")
        expect(isNewerVersion("1.0", than: "0.9.9"))
        expect(isNewerVersion("v0.2.0", than: "0.1.0"), "leading v ignored")
        expect(!isNewerVersion("0.1.0", than: "0.1.0"), "equal is not newer")
        expect(!isNewerVersion("0.1", than: "0.1.0"), "missing parts count as 0")
        expect(!isNewerVersion("0.1.0", than: "0.1.1"))
    }
}

func testWeekBudget() {
    // Window: Monday 16 Nov 2026 00:00 UTC → Monday 23 Nov.
    let reset = date(2026, 11, 23)

    suite("WeekBudget: 7 even days") {
        let b = WeekBudget(resetsAt: reset, now: date(2026, 11, 18, 12), mode: 0, custom: [], calendar: utc)!
        expectEqual(b.boundaries.count, 8)
        expectClose(b.boundaries[3], 3.0 / 7)
        expectEqual(b.current, 2, "Wednesday is slice 2")
        expectClose(b.expected, 2.5 / 7)
    }

    suite("WeekBudget: weekdays only") {
        let wed = WeekBudget(resetsAt: reset, now: date(2026, 11, 18, 12), mode: 1, custom: [], calendar: utc)!
        expectClose(wed.shares[0], 0.2)
        expectClose(wed.shares[5], 0, "Saturday gets no budget")
        expectClose(wed.expected, 0.5, "2.5 of 5 weekdays")
        let sat = WeekBudget(resetsAt: reset, now: date(2026, 11, 21, 12), mode: 1, custom: [], calendar: utc)!
        expectClose(sat.expected, 1, "whole budget available by the weekend")
    }

    suite("WeekBudget: custom split") {
        let b = WeekBudget(resetsAt: reset, now: date(2026, 11, 22, 6), mode: 2,
                           custom: [16, 16, 16, 16, 16, 10, 10], calendar: utc)!
        expectClose(b.boundaries[5], 0.8)
        expectEqual(b.current, 6)
        expectClose(b.expected, 0.925, "Sunday 06:00: 90% + a quarter of 10%")
        let zero = WeekBudget(resetsAt: reset, now: date(2026, 11, 18), mode: 2,
                              custom: [0, 0, 0, 0, 0, 0, 0], calendar: utc)!
        expectClose(zero.shares[0], 1.0 / 7, "all-zero split falls back to even")
        expect(WeekBudget(resetsAt: nil, now: Date(), mode: 0, custom: []) == nil, "no reset time, no budget")
    }
}

func testForecast() {
    let now = date(2026, 11, 16, 12)
    let resets = now.addingTimeInterval(4 * 3600)   // 1h into a 5h session

    suite("Forecast.hitTime") {
        expect(ForecastMath.hitTime(util: 10, resetsAt: resets, duration: 5 * 3600, now: now, recent: nil) == nil,
               "10% in an hour lasts until reset")
        expectClose(ForecastMath.hitTime(util: 50, resetsAt: resets, duration: 5 * 3600, now: now, recent: nil)?
                        .timeIntervalSince(now), 3600, "50%/h with 50% left → 1h")
        expectEqual(ForecastMath.hitTime(util: 100, resetsAt: resets, duration: 5 * 3600, now: now, recent: nil), now)
        expect(ForecastMath.hitTime(util: 50, resetsAt: nil, duration: 5 * 3600, now: now, recent: nil) == nil)

        // Recent burn beats the window average: 20% → 40% in 10 minutes = 2%/min, 60% left → 30 min.
        let w = windowKey(resets)
        let recent = [ForecastMath.Sample(t: now.addingTimeInterval(-600), util: 20, window: w)]
        expectClose(ForecastMath.hitTime(util: 40, resetsAt: resets, duration: 5 * 3600, now: now, recent: recent)?
                        .timeIntervalSince(now), 1800)
        // Under 8 minutes of samples: fall back to the window average (40%/h → 1.5h).
        let short = [ForecastMath.Sample(t: now.addingTimeInterval(-300), util: 20, window: w)]
        expectClose(ForecastMath.hitTime(util: 40, resetsAt: resets, duration: 5 * 3600, now: now, recent: short)?
                        .timeIntervalSince(now), 1.5 * 3600)
    }
}

func testGrid() {
    suite("gridLattice") {
        // 180pt pitch, 16pt margins on a 1728pt-wide screen; from the left edge.
        let left = gridLattice(16, len: 360, lo: 16, hi: 1712, pitch: 180)
        expectEqual(left.first, 16)
        expect(left.allSatisfy { $0 + 360 <= 1712.5 }, "every slot fits")
        // From the right edge: the last slot is flush 16pt from the right.
        let right = gridLattice(1712 - 360, len: 360, lo: 16, hi: 1712, pitch: 180)
        expectEqual(right.last, 1352)
        expectEqual(right.first, 92, "1352 - 7×180")
        expectEqual(gridLattice(0, len: 500, lo: 0, hi: 300, pitch: 180), [0], "too small: just lo")
    }
}
