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

func testDayNames() {
    suite("Weekday names follow the Mac's language, Monday first") {
        let s = Calendar.current.shortWeekdaySymbols
        expectEqual(WeekBudget.dayNames.count, 7)
        expectEqual(WeekBudget.dayNames.first, s[1], "Monday first")
        expectEqual(WeekBudget.dayNames.last, s[0], "Sunday last")
    }
}

func testRestEvenly() {
    // Window: Mon 16 Nov 00:00 UTC → Mon 23 Nov. Thursday noon is slot 3.
    let reset = date(2026, 11, 23)
    suite("WeekBudget: rest evenly") {
        let b = WeekBudget(resetsAt: reset, now: date(2026, 11, 19, 12), mode: 3, custom: [],
                           usedBeforeToday: 0.6, calendar: utc)!
        expectEqual(b.current, 3)
        expectClose(b.boundaries[1], 0.6, "days gone: one slice of what they used")
        expectClose(b.boundaries[3], 0.6, "the other past slices are empty")
        expectClose(b.shares[3], 0.1, "40% left over 4 days")
        expectClose(b.boundaries[7], 1)
        expectClose(b.expected, 0.65, "half-way through today: 60% + 5%")
        let light = WeekBudget(resetsAt: reset, now: date(2026, 11, 19, 12), mode: 3, custom: [],
                               usedBeforeToday: 0.2, calendar: utc)!
        expectClose(light.shares[6], 0.2, "used little: 80% over 4 days")
        let first = WeekBudget(resetsAt: reset, now: date(2026, 11, 16, 6), mode: 3, custom: [],
                               usedBeforeToday: 0.3, calendar: utc)!
        expectClose(first.shares[0], 1.0 / 7, "first day: nothing gone yet, 7 even days")
        let unknown = WeekBudget(resetsAt: reset, now: date(2026, 11, 19, 12), mode: 3, custom: [], calendar: utc)!
        expectClose(unknown.shares[3], 0.25, "no start reading: what's left is all of it")
    }

    suite("DayStartLog keeps the first reading of each day slot") {
        withDefaults { d in
            DayStartLog.record(weeklyUtil: 55, resetsAt: reset, now: date(2026, 11, 19, 1), defaults: d)
            DayStartLog.record(weeklyUtil: 70, resetsAt: reset, now: date(2026, 11, 19, 15), defaults: d)
            expectClose(DayStartLog.usedBeforeToday(resetsAt: reset, now: date(2026, 11, 19, 20), defaults: d), 0.55)
            expect(DayStartLog.usedBeforeToday(resetsAt: reset, now: date(2026, 11, 20, 2), defaults: d) == nil,
                   "next day: unknown until its first reading")
            DayStartLog.record(weeklyUtil: 72, resetsAt: reset, now: date(2026, 11, 20, 2), defaults: d)
            expectClose(DayStartLog.usedBeforeToday(resetsAt: reset, now: date(2026, 11, 20, 9), defaults: d), 0.72)
        }
    }
}
