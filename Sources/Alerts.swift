// Limit alerts (80% / 95% / session reset) and run-out forecasting.

import AppKit
import SwiftUI
import UserNotifications

enum Notifier {
    static func post(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        }
    }
}

/// Minute-resolution key for a reset time (the API's fractional seconds jitter between calls).
func windowKey(_ d: Date) -> Int { Int((d.timeIntervalSince1970 / 60).rounded()) }

// MARK: - Threshold & reset alerts

enum LimitAlerts {
    /// Alert groups, each with its own on/off switch and threshold list.
    static let groups: [(key: String, title: String, subtitle: String)] = [
        ("session", "Session limit", "The 5-hour limit"),
        ("weekly", "Weekly limit", "All models, 7 days"),
        ("scoped", "Model limits", "e.g. Fable weekly"),
    ]
    static let defaultThresholds = [80, 95]

    static func thresholds(_ key: String) -> [Int] {
        ((UserDefaults.standard.array(forKey: "alertThresholds.\(key)") as? [Int]) ?? defaultThresholds).sorted()
    }
    static func enabled(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: "alertEnabled.\(key)") as? Bool ?? true
    }

    /// Called after every successful fetch.
    static func check(_ u: Usage, now: Date) {
        let d = UserDefaults.standard
        // Remember the session window so we can announce its reset later.
        if let util = u.five_hour?.utilization, let r = parseDate(u.five_hour?.resets_at) {
            d.set(util, forKey: "lastSessionUtil")
            d.set(r.timeIntervalSince1970, forKey: "lastSessionReset")
        }

        // (group key, display name, phrase used in the body, usage, reset time)
        var items: [(key: String, name: String, phrase: String, util: Double?, reset: Date?)] = [
            ("session", "Session limit", "5-hour session limit", u.five_hour?.utilization, parseDate(u.five_hour?.resets_at)),
            ("weekly", "Weekly limit", "weekly limit (all models)", u.seven_day?.utilization, parseDate(u.seven_day?.resets_at)),
        ]
        for l in (u.limits ?? []) where l.kind == "weekly_scoped" {
            let model = l.scope?.model?.display_name ?? "Model"
            items.append(("scoped", "\(model) weekly limit", "\(model) weekly limit", l.percent, parseDate(l.resets_at)))
        }

        for it in items where enabled(it.key) {
            let list = thresholds(it.key).map(Double.init)
            guard let util = it.util, let reset = it.reset,
                  let hit = list.last(where: { util >= $0 }) else { continue }
            let base = "alert-\(it.name)-\(windowKey(reset))"
            guard !d.bool(forKey: "\(base)-\(Int(hit))") else { continue }
            for t in list where t <= hit { d.set(true, forKey: "\(base)-\(Int(t))") }

            Notifier.post(id: "\(base)-\(Int(hit))",
                          title: "\(it.name): \(Int(util))% used",
                          body: "You've used \(Int(util))% of your \(it.phrase). It \(resetText(reset, now: now)).")
        }
    }

    /// Called on the clock tick: announces when a well-used session window has rolled over.
    static func checkSessionReset(now: Date) {
        guard UserDefaults.standard.object(forKey: "sessionResetAlert") as? Bool ?? true else { return }
        let d = UserDefaults.standard
        let r = d.double(forKey: "lastSessionReset"), util = d.double(forKey: "lastSessionUtil")
        let since = now.timeIntervalSince1970 - r
        guard r > 0, since >= 0, since < 15 * 60, util >= 50 else { return }
        let key = "sessionReset-\(Int((r / 60).rounded()))"
        guard !d.bool(forKey: key) else { return }
        d.set(true, forKey: key)
        Notifier.post(id: key, title: "Session limit reset",
                      body: "Your 5-hour session is fresh again. You'd used \(Int(util))% of the last one.")
    }
}

// MARK: - Forecast

enum Forecast {
    struct Sample { let t: Date; let util: Double; let window: Int }
    @MainActor static var session: [Sample] = []

    @MainActor static func record(_ u: Usage, now: Date) {
        guard let util = u.five_hour?.utilization, let r = parseDate(u.five_hour?.resets_at) else { return }
        session.append(Sample(t: now, util: util, window: windowKey(r)))
        session.removeAll { now.timeIntervalSince($0.t) > 3600 }
    }

    /// When the limit will be hit at the current burn rate, or nil if it should last until reset.
    /// Session uses the last ~30 minutes of samples when available; otherwise the whole-window average.
    @MainActor static func hitTime(util: Double, resetsAt: Date?, duration: TimeInterval,
                                   now: Date, useRecent: Bool) -> Date? {
        guard let resetsAt else { return nil }
        if util >= 100 { return now }
        let elapsed = duration - resetsAt.timeIntervalSince(now)
        var rate: Double?   // percent per second

        if useRecent {
            let w = windowKey(resetsAt)
            let pts = session.filter { abs($0.window - w) <= 2 && now.timeIntervalSince($0.t) <= 30 * 60 }
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

/// Same threshold PaceNote uses for "Ahead of pace".
func aheadOfPace(_ percent: Double, _ elapsed: Double?) -> Bool {
    guard let elapsed else { return false }
    return percent - elapsed * 100 >= 3
}

/// Only shown when you're ahead of pace and on course to hit the limit before it resets.
struct ForecastNote: View {
    let hit: Date?
    let now: Date
    var short = false

    var body: some View {
        if let hit {
            let sameDay = Calendar.current.isDate(hit, inSameDayAs: now)
            let time = sameDay ? hit.formatted(.dateTime.hour().minute())
                               : hit.formatted(.dateTime.weekday(.abbreviated).hour())
            Label(hit <= now ? "Limit reached" : (short ? "Out ~\(time)" : "Runs out ~\(time)"),
                  systemImage: "hourglass")
                .font(.system(size: short ? 10 : 11, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Palette.rust)
                .lineLimit(1)
                .help("At your current rate you'll hit this limit before it resets.")
        }
    }
}
