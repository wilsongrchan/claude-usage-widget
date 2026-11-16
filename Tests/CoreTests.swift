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
    suite("WeekBudget: split") {
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
        expectClose(unknown.shares[3], 1.0 / 7, "no start reading for today: falls back to 7 even days")
        expectClose(unknown.boundaries[3], 3.0 / 7)
        expectClose(unknown.expected, 3.5 / 7)
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

func testSnapping() {
    suite("bestSlot lines up with native widgets next to them") {
        // A native column 8pt off the screen-edge grid (as on the owner's second Mac).
        let native = [Slot(x: 8, y: 820, w: 360, h: 180)]
        let edge = [16.0, 196], nativeX: Set<Double> = [8, 188]
        let ys = [460.0, 640, 1000], nativeY: Set<Double> = [460, 640]
        // Our large widget sits just below it, on the edge grid at x 16.
        let s = bestSlot(near: (16, 460), xs: edge + Array(nativeX), ys: ys, w: 360, h: 360,
                         taken: native, alignedXs: nativeX, alignedYs: nativeY, pitch: 180)
        expectEqual(s?.x, 8, "moves 8pt to line up with the native column")
        expectEqual(s?.y, 460)
        // Far from any native widget, the nearest slot still wins.
        let far = bestSlot(near: (1000, 100), xs: [1000, 1008], ys: [100], w: 180, h: 180,
                           taken: native, alignedXs: [1008], alignedYs: [100], pitch: 180)
        expectEqual(far?.x, 1000, "no pull towards the native grid away from native widgets")
        // A free slot always beats one a native widget covers.
        let covered = bestSlot(near: (8, 820), xs: [8], ys: [820, 640], w: 360, h: 180,
                               taken: native, alignedXs: [8], alignedYs: [820, 640], pitch: 180)
        expectEqual(covered?.y, 640, "never on top of a native widget")
    }
}

func testResetTimes() {
    let now = date(2026, 11, 16, 12, 57)   // Monday 12:57 UTC
    suite("Reset times: time left or clock time") {
        expectEqual(ResetTimes.countdown(3 * 3600 + 13 * 60), "3h 13m")
        expectEqual(ResetTimes.countdown(2 * 86400 + 19 * 3600 + 5), "2d 19h")
        expectEqual(ResetTimes.countdown(20), "1m")
        let later = date(2026, 11, 16, 16, 10), monday = date(2026, 11, 23, 9), half = date(2026, 11, 17, 1, 42)
        expectEqual(ResetTimes.phrase(later, now: now, clock: false, h24: false, calendar: utc), "resets in 3h 13m")
        expectEqual(ResetTimes.phrase(later, now: now, clock: true, h24: false, calendar: utc), "resets at 4:10 PM")
        expectEqual(ResetTimes.phrase(later, now: now, clock: true, h24: true, calendar: utc), "resets at 16:10")
        expectEqual(ResetTimes.phrase(monday, now: now, clock: true, h24: false, calendar: utc), "resets Mon 9 AM")
        expectEqual(ResetTimes.phrase(monday, now: now, clock: true, h24: true, calendar: utc), "resets Mon 9:00")
        expectEqual(ResetTimes.phrase(half, now: now, clock: true, h24: false, calendar: utc), "resets Tue 1:42 AM",
                    "another day, not on the hour: keep the minutes")
        expectEqual(ResetTimes.short(later, now: now, clock: true, h24: false, calendar: utc), "at 4:10 PM")
        expectEqual(ResetTimes.short(later, now: now, clock: false, h24: false, calendar: utc), "in 3h 13m")
        expectEqual(ResetTimes.short(monday, now: now, clock: true, h24: false, calendar: utc), "Mon 9 AM")
        expectEqual(ResetTimes.bare(monday, now: now, clock: true, h24: false, calendar: utc), "Mon 9 AM")
        expectEqual(ResetTimes.bare(monday, now: now, clock: false, h24: false, calendar: utc), "6d 20h")
        expectEqual(ResetTimes.phrase(now.addingTimeInterval(-5), now: now, clock: true, h24: false, calendar: utc), "resetting…")
        let labels = ResetTimes.choiceLabels(later, now: now, h24: true, calendar: utc)
        expectEqual(labels.0, "In 3h 13m"); expectEqual(labels.1, "At 16:10")
        let late = ResetTimes.choiceLabels(half, now: now, h24: false, calendar: utc)
        expectEqual(late.1, "Tue 1:42 AM", "a reset after midnight names the day")
        let none = ResetTimes.choiceLabels(nil, now: now, h24: true, calendar: utc)
        expectEqual(none.0, "Time left"); expectEqual(none.1, "Clock time")
    }
}
