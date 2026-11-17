// Small pure helpers shared by the app and the tests.

import Foundation

// MARK: - Forecast

enum ForecastMath {
    struct Sample { let t: Date; let util: Double; let window: Int }

    /// When the limit will be hit at the current burn rate, or nil if it lasts until reset.
    /// With `recent` samples it uses the last ~30 minutes (needs 8+ minutes of them);
    /// otherwise the whole-window average.
    static func hitTime(util: Double, resetsAt: Date?, duration: TimeInterval,
                        now: Date, recent: [Sample]?) -> Date? {
        guard let resetsAt else { return nil }
        if util >= 100 { return now }
        let elapsed = duration - resetsAt.timeIntervalSince(now)
        var rate: Double?   // percent per second

        if let recent {
            let w = windowKey(resetsAt)
            let pts = recent.filter { abs($0.window - w) <= 2 && now.timeIntervalSince($0.t) <= 30 * 60 }
            if let first = pts.first, now.timeIntervalSince(first.t) >= 8 * 60 {
                rate = (util - first.util) / now.timeIntervalSince(first.t)
            }
        }
        if rate == nil, elapsed > 10 * 60 { rate = util / elapsed }
        guard let rate, rate > 0 else { return nil }

        let hit = now.addingTimeInterval((100 - util) / rate)
        return hit < resetsAt ? hit : nil
    }
}

// MARK: - Reset times

/// How reset times read: as time left ("in 3h 13m") or as a clock time ("at 4:10 PM").
enum ResetTimes {
    static let key = "resetTimeStyle"   // 0 = time left, 1 = clock time

    /// "3h 13m", "2d 19h", "5m"
    static func countdown(_ seconds: Int) -> String {
        let d = seconds / 86400, h = (seconds % 86400) / 3600, m = (seconds % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(max(m, 1))m"
    }

    /// Today: "4:10 PM" (24-hour: "16:10"). Another day: "Mon 9 AM", "Mon 9:30 AM" ("Mon 9:00").
    static func clock(_ d: Date, now: Date, h24: Bool, calendar: Calendar = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = calendar.timeZone
        let onHour = calendar.component(.minute, from: d) == 0
        if calendar.isDate(d, inSameDayAs: now) {
            f.dateFormat = h24 ? "H:mm" : "h:mm a"
        } else {
            f.dateFormat = h24 ? "EEE H:mm" : (onHour ? "EEE h a" : "EEE h:mm a")
        }
        return f.string(from: d)
    }

    /// "resets in 3h 13m", "resets at 4:10 PM", "resets Mon 9 AM", or "resetting…".
    static func phrase(_ d: Date, now: Date, clock useClock: Bool, h24: Bool, calendar: Calendar = .current) -> String {
        let s = Int(d.timeIntervalSince(now))
        if s <= 0 { return "resetting…" }
        guard useClock else { return "resets in \(countdown(s))" }
        let c = clock(d, now: now, h24: h24, calendar: calendar)
        return calendar.isDate(d, inSameDayAs: now) ? "resets at \(c)" : "resets \(c)"
    }

    /// For tight spots: "in 3h 13m", "at 4:10 PM", "Mon 9 AM".
    static func short(_ d: Date, now: Date, clock useClock: Bool, h24: Bool, calendar: Calendar = .current) -> String {
        let p = phrase(d, now: now, clock: useClock, h24: h24, calendar: calendar)
        return p.hasPrefix("resets ") ? String(p.dropFirst("resets ".count)) : p
    }

    /// The two choices in Settings, shown with the current session's real reset:
    /// ("In 3h 13m", "At 16:10"). Without a session yet: ("Time left", "Clock time").
    static func choiceLabels(_ d: Date?, now: Date, h24: Bool, calendar: Calendar = .current) -> (String, String) {
        guard let d, d > now else { return ("Time left", "Clock time") }
        func cap(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }
        return (cap(short(d, now: now, clock: false, h24: h24, calendar: calendar)),
                cap(short(d, now: now, clock: true, h24: h24, calendar: calendar)))
    }

    /// After a ↻ icon: "2d 19h", "4:10 PM", "Mon 9 AM".
    static func bare(_ d: Date, now: Date, clock useClock: Bool, h24: Bool, calendar: Calendar = .current) -> String {
        let s = Int(d.timeIntervalSince(now))
        if s <= 0 { return "resetting…" }
        return useClock ? clock(d, now: now, h24: h24, calendar: calendar) : countdown(s)
    }
}

// MARK: - Weekly ring

/// Some plans (Enterprise, for one) have no weekly limit, so the weekly ring would sit at 0%.
enum WeeklyRing {
    static let key = "weeklyRing"   // 0 = show, 1 = hide in the small widget, 2 = hide
    static func shown(_ style: Int, small: Bool) -> Bool { style == 0 || (style == 1 && !small) }
}

// MARK: - Versions

/// "0.2.0" > "0.1.10" > "0.1.9"; a leading "v" is ignored and missing parts count as 0.
func isNewerVersion(_ a: String, than b: String) -> Bool {
    func parts(_ s: String) -> [Int] {
        let t = s.hasPrefix("v") ? String(s.dropFirst()) : s
        return t.split(whereSeparator: { $0 == "." || $0 == "-" }).map { Int($0) ?? 0 }
    }
    let x = parts(a), y = parts(b)
    for i in 0..<max(x.count, y.count) {
        let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
        if p != q { return p > q }
    }
    return false
}

// MARK: - Grid

/// Positions along one axis: every step of `pitch` from `ref` that keeps a span of `len`
/// between `lo` and `hi`. If the span doesn't fit at all, just `lo`.
func gridLattice(_ ref: Double, len: Double, lo: Double, hi: Double, pitch: Double) -> [Double] {
    guard hi - lo >= len - 0.5 else { return [lo] }
    let first = ref + ((lo - ref) / pitch).rounded(.up) * pitch
    return stride(from: first, through: hi - len + 0.5, by: pitch).map { $0 }
}

/// A widget slot on screen (AppKit coordinates: origin bottom-left), in points.
struct Slot: Equatable {
    var x, y, w, h: Double
    func intersects(_ o: Slot, inset: Double = 0) -> Bool {
        x + inset < o.x + o.w && o.x < x + w - inset && y + inset < o.y + o.h && o.y < y + h - inset
    }
    func expanded(by d: Double) -> Slot { Slot(x: x - d, y: y - d, w: w + 2 * d, h: h + 2 * d) }
}

/// Picks where a widget snaps. Free slots beat taken ones. Next to native widgets, a slot on
/// their grid (`alignedXs` × `alignedYs`) wins over a slightly nearer one on the screen-edge
/// grid: the two can be a few points apart, and sitting a few points off a native widget looks
/// wrong. Elsewhere the nearest slot wins.
func bestSlot(near p: (x: Double, y: Double), xs: [Double], ys: [Double], w: Double, h: Double,
              taken: [Slot], alignedXs: Set<Double>, alignedYs: Set<Double>, pitch: Double) -> Slot? {
    var best: (slot: Slot, free: Bool, score: Double)?
    for x in xs {
        for y in ys {
            let s = Slot(x: x.rounded(), y: y.rounded(), w: w, h: h)
            let free = !taken.contains { $0.intersects(s, inset: 1) }
            let aligned = alignedXs.contains(s.x) && alignedYs.contains(s.y)
            let nearNative = taken.contains { $0.intersects(s.expanded(by: 40)) }
            let score = hypot(s.x - p.x, s.y - p.y) - (aligned && nearNative ? pitch / 2 : 0)
            if let b = best {
                if (free && !b.free) || (free == b.free && score < b.score) { best = (s, free, score) }
            } else {
                best = (s, free, score)
            }
        }
    }
    return best?.slot
}

// MARK: - Notifications already sent

/// Which alerts and reminders have already gone out, so each fires once. One dictionary
/// (`notifiedLog`: id → when it was recorded), pruned after 14 days. Saved-reset reminders
/// (`notified-<expiry>-<lead>`) are kept until that expiry has passed, however long the lead.
enum NotifiedLog {
    static let key = "notifiedLog"
    static let maxAge: TimeInterval = 14 * 86400
    /// Older versions kept one preference per notification under these prefixes.
    static let legacyPrefixes = ["alert-", "sessionReset-", "notified-"]

    static func contains(_ id: String, defaults d: UserDefaults = .standard) -> Bool {
        (d.dictionary(forKey: key) ?? [:])[id] != nil
    }

    static func record(_ ids: [String], now: Date, defaults d: UserDefaults = .standard) {
        var log = d.dictionary(forKey: key) ?? [:]
        for id in ids { log[id] = now.timeIntervalSince1970 }
        d.set(log, forKey: key)
    }

    static func prune(now: Date, defaults d: UserDefaults = .standard) {
        guard var log = d.dictionary(forKey: key) else { return }
        let cutoff = now.timeIntervalSince1970 - maxAge
        log = log.filter { id, recorded in
            if ((recorded as? Double) ?? 0) >= cutoff { return true }
            if id.hasPrefix("notified-"), let expiry = legacyTime(id) { return expiry >= now.timeIntervalSince1970 }
            return false
        }
        d.set(log, forKey: key)
    }

    /// One-off: drop the old per-notification keys. Ones that could still fire again (their
    /// window or expiry is recent or ahead) move into the log first, so nothing repeats.
    /// `alertThresholds.*` and `alertEnabled.*` are settings and don't match these prefixes.
    static func migrateLegacy(now: Date, defaults d: UserDefaults = .standard) {
        let keys = d.dictionaryRepresentation().keys.filter { k in legacyPrefixes.contains { k.hasPrefix($0) } }
        guard !keys.isEmpty else { return }
        var keep: [String] = []
        for k in keys {
            if let t = legacyTime(k), t >= now.timeIntervalSince1970 - maxAge { keep.append(k) }
            d.removeObject(forKey: k)
        }
        record(keep, now: now, defaults: d)
    }

    /// The time a legacy key refers to: alert-<name>-<window minutes>-<threshold>,
    /// sessionReset-<minutes>, notified-<expiry seconds>-<lead>.
    static func legacyTime(_ k: String) -> Double? {
        let parts = k.split(separator: "-")
        if k.hasPrefix("alert-"), parts.count >= 3, let m = Double(parts[parts.count - 2]) { return m * 60 }
        if k.hasPrefix("sessionReset-"), let m = Double(parts.last ?? "") { return m * 60 }
        if k.hasPrefix("notified-"), parts.count >= 3, let s = Double(parts[1]) { return s }
        return nil
    }
}
