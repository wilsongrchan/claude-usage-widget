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

// MARK: - Notifications already sent

/// Which alerts and reminders have already gone out, so each fires once. One dictionary
/// (`notifiedLog`: id → when it was recorded), pruned after 14 days.
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
        log = log.filter { (($1 as? Double) ?? 0) >= cutoff }
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
