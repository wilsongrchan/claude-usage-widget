// Weekly budget splits and the hourly usage log. No UI here.

import Foundation

func uniformSlices(_ n: Int) -> [Double] { (0...n).map { Double($0) / Double(n) } }

// MARK: - Weekly budget

/// How the weekly limit is split across the 7 days of the current window.
/// Mode 0 = 7 even days, 1 = weekdays only (Mon–Fri), 2 = custom % per weekday,
/// 3 = rest evenly: what was used before today is one slice, and what's left is shared
/// equally by today and the days still to come.
struct WeekBudget {
    /// Short weekday names in the Mac's language, Monday first ("Mon"… or "lun."…).
    static var dayNames: [String] {
        let s = Calendar.current.shortWeekdaySymbols   // Sunday first
        return Array(s[1...]) + [s[0]]
    }
    static let defaultCustom: [Double] = [16, 16, 16, 16, 16, 10, 10]

    let boundaries: [Double]   // cumulative fractions, 8 values from 0 to 1
    let shares: [Double]       // normalised share of each window day
    let expected: Double       // where usage "should" be right now (0…1)
    let current: Int           // index of today's slice

    static var custom: [Double] {
        let a = (UserDefaults.standard.array(forKey: "customAlloc") as? [Double]) ?? defaultCustom
        return a.count == 7 ? a : defaultCustom
    }

    /// Mon = 0 … Sun = 6
    static func weekdayIndex(_ d: Date, calendar: Calendar = .current) -> Int {
        (calendar.component(.weekday, from: d) + 5) % 7
    }

    /// Uses the split chosen in Settings.
    init?(resetsAt: Date?, now: Date) {
        self.init(resetsAt: resetsAt, now: now,
                  mode: UserDefaults.standard.integer(forKey: "weeklySplit"), custom: WeekBudget.custom,
                  usedBeforeToday: DayStartLog.usedBeforeToday(resetsAt: resetsAt, now: now))
    }

    /// `usedBeforeToday` (0…1 of the weekly limit, mode 3 only): usage when today's slot began.
    init?(resetsAt: Date?, now: Date, mode: Int, custom: [Double], usedBeforeToday: Double? = nil,
          calendar: Calendar = .current) {
        guard let resetsAt else { return nil }
        let custom = custom.count == 7 ? custom : WeekBudget.defaultCustom
        let start = resetsAt.addingTimeInterval(-7 * 86400)
        let t = now.timeIntervalSince(start)
        let k = min(max(Int(t / 86400), 0), 6)
        let frac = min(max((t - Double(k) * 86400) / 86400, 0), 1)
        current = k

        // Rest evenly needs today's starting figure; until it's known, use 7 even days.
        if mode == 3, k == 0 || usedBeforeToday != nil {
            // Days already gone collapse into one slice of what they used (zero-width slices
            // aren't drawn); the rest of the limit is split evenly from today on.
            let used = k == 0 ? 0 : min(max(usedBeforeToday ?? 0, 0), 1)
            let each = (1 - used) / Double(7 - k)
            var b = [0.0]
            for day in 0..<7 { b.append(day < k ? used : used + each * Double(day - k + 1)) }
            b[7] = 1
            boundaries = b
            shares = (0..<7).map { b[$0 + 1] - b[$0] }
            expected = b[k] + frac * shares[k]
            return
        }

        var raw = (0..<7).map { k -> Double in
            let idx = WeekBudget.weekdayIndex(start.addingTimeInterval(Double(k) * 86400 + 60), calendar: calendar)
            switch mode {
            case 1: return idx < 5 ? 1 : 0
            case 2: return max(custom[idx], 0)
            default: return 1
            }
        }
        if raw.reduce(0, +) <= 0 { raw = Array(repeating: 1, count: 7) }
        let sum = raw.reduce(0, +)
        shares = raw.map { $0 / sum }

        var b = [0.0]
        for s in shares { b.append(b.last! + s) }
        b[7] = 1
        boundaries = b
        expected = boundaries[k] + frac * shares[k]
    }
}

/// Weekly usage at the start of each day slot of the limit week (for "Rest evenly"). The first
/// reading in a new slot is taken as its start; if the app wasn't running then, that's a little late.
enum DayStartLog {
    static let key = "weeklyDayStart"   // [window, slot, utilization 0…100]

    static func slot(resetsAt: Date, now: Date) -> Int {
        min(max(Int(now.timeIntervalSince(resetsAt.addingTimeInterval(-7 * 86400)) / 86400), 0), 6)
    }

    /// Called with every reading.
    static func record(weeklyUtil: Double, resetsAt: Date?, now: Date, defaults d: UserDefaults = .standard) {
        guard let resetsAt else { return }
        let w = Double(windowKey(resetsAt)), s = Double(slot(resetsAt: resetsAt, now: now))
        if let a = d.array(forKey: key) as? [Double], a.count == 3, abs(a[0] - w) <= 2, a[1] == s { return }
        d.set([w, s, weeklyUtil], forKey: key)
    }

    /// 0…1 of the weekly limit used before today's slot began, if known.
    static func usedBeforeToday(resetsAt: Date?, now: Date, defaults d: UserDefaults = .standard) -> Double? {
        guard let resetsAt, let a = d.array(forKey: key) as? [Double], a.count == 3,
              abs(a[0] - Double(windowKey(resetsAt))) <= 2,
              a[1] == Double(slot(resetsAt: resetsAt, now: now)) else { return nil }
        return a[2] / 100
    }
}

// MARK: - Hourly usage log (today's session usage, bucketed by hour)

enum HourlyLog {
    static let prefix = "hourly-"
    static let keepDays = 7

    static func key(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return "\(prefix)\(c.year!)-\(c.month!)-\(c.day!)"
    }

    static func today(_ now: Date, defaults d: UserDefaults = .standard) -> [Double] {
        let a = (d.array(forKey: key(now)) as? [Double]) ?? []
        return a.count == 24 ? a : Array(repeating: 0, count: 24)
    }

    /// Attributes the rise in session usage since the last reading to the current hour.
    static func record(_ u: Usage, now: Date, defaults d: UserDefaults = .standard) {
        let util = u.five_hour?.utilization ?? 0
        let win = parseDate(u.five_hour?.resets_at).map(windowKey) ?? 0
        defer {
            d.set(util, forKey: "hl.lastUtil")
            d.set(win, forKey: "hl.lastWin")
        }
        guard d.object(forKey: "hl.lastUtil") != nil else { return }   // first run: no baseline yet
        let lastUtil = d.double(forKey: "hl.lastUtil"), lastWin = d.integer(forKey: "hl.lastWin")
        // Same session window → the increase; new window → everything used since it began.
        let delta = abs(win - lastWin) <= 2 ? max(util - lastUtil, 0) : util
        guard delta > 0 else { return }
        var arr = today(now, defaults: d)
        arr[Calendar.current.component(.hour, from: now)] += delta
        d.set(arr, forKey: key(now))
    }

    /// Deletes days older than `keepDays` (today counts as day 1).
    static func prune(now: Date, defaults d: UserDefaults = .standard) {
        let cal = Calendar.current
        let cutoff = cal.date(byAdding: .day, value: -(keepDays - 1), to: cal.startOfDay(for: now))!
        for key in d.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
            let parts = key.dropFirst(prefix.count).split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3,
                  let day = cal.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else {
                continue
            }
            if day < cutoff { d.removeObject(forKey: key) }
        }
    }
}
