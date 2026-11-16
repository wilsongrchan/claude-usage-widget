// Claude Usage Widget — a Liquid Glass desktop widget showing live Claude plan limits.
// Reads the Claude Code login from the macOS Keychain (never stored or logged)
// and polls https://api.anthropic.com/api/oauth/usage.

import AppKit
import SwiftUI
import UserNotifications

// MARK: - Data store

@MainActor
final class UsageStore: ObservableObject {
    @Published var usage: Usage?
    /// What's stopping a reading (login expired, no Claude Code, HTTP error…), if anything.
    @Published var problem: UsageProblem?
    @Published var lastUpdated: Date?
    @Published var now = Date()
    @Published var loading = false
    /// True when the desktop isn't focused: the widget fades like native widgets.
    @Published var dimmed = false
    /// Soft status (rate limited / offline) shown in grey while the last good data stays on screen.
    @Published var pausedReason: String?
    @Published var nextRetry: Date?

    /// Long form, for the large widget and popover.
    var error: String? { problem.map { "\($0.short). \($0.long)" } }

    // Polling: every minute normally, every 5 minutes while the display sleeps or the screen is
    // locked (Claude Code can still be working, and alerts still matter), longer when rate limited.
    private static let activeInterval: TimeInterval = 60
    private static let idleInterval: TimeInterval = 300
    private var idleReasons: Set<String> = []
    private var backoff: TimeInterval?
    private var pollInterval: TimeInterval { max(idleReasons.isEmpty ? Self.activeInterval : Self.idleInterval, backoff ?? 0) }
    private var scheduledInterval: TimeInterval?
    private var pollTimer: Timer?
    private var clockTimer: Timer?

    // The login lives in memory only. The secret is read again only when there's no login in
    // memory, the user pressed Refresh, or the login expired / was rejected AND Claude Code has
    // written a new one since (seen from the Keychain item's dates, which never prompt). With
    // plain "Allow" that keeps prompts to launch and Claude Code's own login renewals.
    private var credentials: Credentials?
    private var credentialsStamp: String?
    /// The token the API rejected; until Claude Code writes a new one, polls skip the network.
    private var rejectedToken: String?
    /// After Deny on the Keychain prompt, don't ask again on every poll: wait for Refresh.
    private var keychainDenied = false
    private var refreshing = false
    /// False on first launch until the welcome window's Connect (or any Refresh): polls don't
    /// touch the Keychain before the user knows why macOS is about to ask.
    var keychainAllowed = true

    func allowKeychain() {
        guard !keychainAllowed else { return }
        keychainAllowed = true
        Task { await refresh() }
    }

    /// "Updates paused · retrying in 4m" etc.
    var notice: String? {
        guard let pausedReason else { return nil }
        if let nextRetry, nextRetry > now {
            let s = Int(nextRetry.timeIntervalSince(now))
            return "\(pausedReason) · retrying in \(s >= 60 ? "\(s / 60)m" : "\(max(s, 1))s")"
        }
        return "\(pausedReason) · retrying"
    }

    func start() {
        // Show the last good reading immediately, and skip the launch fetch if it's very fresh.
        let d = UserDefaults.standard
        if let data = d.data(forKey: "lastUsageData"),
           let cached = try? JSONDecoder().decode(Usage.self, from: data) {
            usage = cached
            lastUpdated = d.object(forKey: "lastUsageDate") as? Date
        }
        if !isFresh { Task { await refresh() } }
        schedulePoll()

        let ws = NSWorkspace.shared.notificationCenter
        // Catch up straight after the Mac wakes instead of waiting for the next poll.
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))   // let the network come back first
                await self.refresh()
            }
        }
        // Display asleep, screen locked or another user's session in front: poll less often.
        let idle: [(Notification.Name, Notification.Name, String, NotificationCenter)] = [
            (NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification, "display", ws),
            (NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification, "session", ws),
            (Notification.Name("com.apple.screenIsLocked"), Notification.Name("com.apple.screenIsUnlocked"), "locked",
             DistributedNotificationCenter.default()),
        ]
        for (begin, end, reason, center) in idle {
            center.addObserver(forName: begin, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { self.setIdle(reason, true) }
            }
            center.addObserver(forName: end, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { self.setIdle(reason, false) }
            }
        }

        clockTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in
            Task { @MainActor in
                self.now = Date(); ResetReminder.check(); LimitAlerts.checkSessionReset(now: Date())
                Housekeeping.runIfDue(now: Date())
            }
        }
    }

    private var isFresh: Bool { lastUpdated.map { Date().timeIntervalSince($0) < 50 } ?? false }

    private func setIdle(_ reason: String, _ on: Bool) {
        let wasIdle = !idleReasons.isEmpty
        if on { idleReasons.insert(reason) } else { idleReasons.remove(reason) }
        schedulePoll()
        // Back in front of the screen: catch up at once if the reading is stale.
        if wasIdle && idleReasons.isEmpty && !isFresh { Task { await refresh() } }
    }

    private func schedulePoll() {
        guard scheduledInterval != pollInterval else { return }
        scheduledInterval = pollInterval
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { _ in
            Task { @MainActor in await self.refresh() }
        }
    }

    /// `userInitiated`: the Refresh button, which also re-reads the login from the Keychain.
    func refresh(userInitiated: Bool = false) async {
        // One at a time: the poll, wake and Refresh can overlap, and each Keychain read can show
        // a prompt (left unanswered, overlapping refreshes would stack up prompts).
        guard !refreshing else { return }
        guard keychainAllowed || userInitiated else { return }
        keychainAllowed = true
        if keychainDenied && !userInitiated { return }
        keychainDenied = false
        refreshing = true
        loading = true
        defer { refreshing = false; loading = false; now = Date() }

        do {
            var readSecret = false   // never read the secret twice in one refresh
            var creds = try await login(userInitiated: userInitiated, readSecret: &readSecret)
            let result: (Usage, Data)
            do {
                result = try await Self.fetch(token: creds.token)
            } catch UsageProblem.loginExpired {
                rejectedToken = creds.token
                // Just read and still rejected: it really has expired. Otherwise Claude Code may
                // have renewed it since we read it: retry once if (and only if) it wrote a new one.
                guard !readSecret else { throw UsageProblem.loginExpired }
                creds = try await login(userInitiated: false, readSecret: &readSecret)
                result = try await Self.fetch(token: creds.token)
            }
            accept(result)
        } catch let r as RateLimited {
            // Back off: honour the server's Retry-After (up to an hour), else double the wait (max 10 min).
            problem = nil
            pausedReason = "Updates paused"
            backoff = min(max(r.retryAfter.map { min($0, 3600) } ?? pollInterval * 2, 60),
                          r.retryAfter == nil ? 600 : 3600)
            nextRetry = Date().addingTimeInterval(pollInterval)
            schedulePoll()
        } catch is URLError {
            problem = nil
            pausedReason = "Offline"
            nextRetry = Date().addingTimeInterval(pollInterval)
        } catch let p as UsageProblem {
            pausedReason = nil
            keychainDenied = p == .keychainDenied
            if p == .loginExpired, rejectedToken == nil, let t = credentials?.token { rejectedToken = t }
            problem = p
        } catch {
            pausedReason = nil
            problem = .badResponse
        }
    }

    private func accept(_ result: (Usage, Data)) {
        let (u, raw) = result
        usage = u
        problem = nil
        pausedReason = nil
        nextRetry = nil
        lastUpdated = Date()
        UserDefaults.standard.set(raw, forKey: "lastUsageData")
        UserDefaults.standard.set(lastUpdated, forKey: "lastUsageDate")
        Forecast.record(u, now: Date())
        HourlyLog.record(u, now: Date())
        DayStartLog.record(weeklyUtil: u.seven_day?.utilization ?? 0, resetsAt: parseDate(u.seven_day?.resets_at), now: Date())
        LimitAlerts.check(u, now: Date())
        if backoff != nil { backoff = nil; schedulePoll() }
    }

    /// The login to use for this refresh, following `LoginPlan`.
    private func login(userInitiated: Bool, readSecret: inout Bool) async throws -> Credentials {
        let cached = credentials, cachedStamp = credentialsStamp
        let rejected = rejectedToken != nil && rejectedToken == cached?.token
        let plan = await Task.detached {
            LoginPlan.decide(cached: cached, cachedStamp: cachedStamp, rejected: rejected,
                             userInitiated: userInitiated, now: Date(), currentStamp: { Credentials.stamp() })
        }.value
        switch plan {
        case .useCached:
            return cached!
        case .expired:
            throw UsageProblem.loginExpired
        case .readSecret:
            guard !readSecret else { throw UsageProblem.loginExpired }
            readSecret = true
            do {
                // Stamp first: if Claude Code writes in between, the next poll sees a change.
                let (stamp, c) = try await Task.detached { (Credentials.stamp(), try Credentials.read()) }.value
                credentials = c
                credentialsStamp = stamp
                if c.token == rejectedToken {
                    // The same login it was before: still expired, and don't re-read until it changes.
                    throw UsageProblem.loginExpired
                }
                rejectedToken = nil
                return c
            } catch let p as UsageProblem where p == .loginExpired {
                throw p
            } catch {
                credentials = nil
                credentialsStamp = nil
                throw error
            }
        }
    }

    nonisolated static func fetch(token: String) async throws -> (Usage, Data) {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("claude-usage-widget/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20
        // A fresh session per poll: the shared one can keep reusing a connection that died
        // across sleep or a network change, so every request silently times out forever.
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        switch code {
        case 200:
            guard let u = try? JSONDecoder().decode(Usage.self, from: data) else { throw UsageProblem.badResponse }
            return (u, data)
        case 401, 403: throw UsageProblem.loginExpired
        case 429:
            let retry = (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
            throw RateLimited(retryAfter: retry)
        default: throw UsageProblem.unavailable(status: code)
        }
    }
}

// MARK: - Faded (monochrome) state

private struct WidgetDimmedKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// True while the widget is in its faded, native-widget style; small text switches to near-white.
    var widgetDimmed: Bool {
        get { self[WidgetDimmedKey.self] }
        set { self[WidgetDimmedKey.self] = newValue }
    }
}

// MARK: - Claude palette

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

enum Palette {
    static let claude = Color(hex: 0xD97757)   // Claude orange
    static let peach  = Color(hex: 0xEBA683)   // light terracotta
    static let ember  = Color(hex: 0xB9531C)   // dark orange
    /// Dark red, nearing the limit. On dark backgrounds #9B1C1C is hard to read, so dark mode
    /// uses a lighter red.
    static let rust = Color(nsColor: NSColor(name: "rust") { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0xC9 / 255, green: 0x31 / 255, blue: 0x2C / 255, alpha: 1)   // owner's pick: red, not orange
            : NSColor(srgbRed: 0x9B / 255, green: 0x1C / 255, blue: 0x1C / 255, alpha: 1)
    })
    static let cream  = Color(hex: 0xF4F3EE)
}

/// Main fill colour, deepening from Claude orange to rust as usage climbs.
func usageColor(_ pct: Double) -> Color {
    switch pct {
    case ..<60: return Palette.claude
    case ..<85: return Palette.ember
    default:    return Palette.rust
    }
}

// MARK: - Formatting helpers

func resetText(_ date: Date?, now: Date) -> String {
    guard let date else { return "—" }
    let s = Int(date.timeIntervalSince(now))
    if s <= 0 { return "resetting…" }
    let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
    if d > 0 { return "resets in \(d)d \(h)h" }
    if h > 0 { return "resets in \(h)h \(m)m" }
    return "resets in \(max(m, 1))m"
}

/// The 5-hour session has no reset time until the first message starts it.
func sessionResetText(_ date: Date?, now: Date) -> String {
    date == nil ? "starts when you use Claude" : resetText(date, now: now)
}

/// "just now", "3m ago", "2h ago"
func ageText(_ d: Date?, now: Date) -> String? {
    guard let d else { return nil }
    let s = Int(now.timeIntervalSince(d))
    if s < 60 { return "just now" }
    if s < 3600 { return "\(s / 60)m ago" }
    if s < 86400 { return "\(s / 3600)h ago" }
    return "\(s / 86400)d ago"
}

/// Fraction of the window that has elapsed (0…1).
func elapsedFraction(resetsAt: Date?, duration: TimeInterval, now: Date) -> Double? {
    guard let resetsAt else { return nil }
    return min(max(1 - resetsAt.timeIntervalSince(now) / duration, 0), 1)
}

// MARK: - Gauges

/// A ring gauge. With `segments > 1` the ring is split into equal slices (e.g. 7 days of a week).
struct RingGauge: View {
    let percent: Double
    let elapsed: Double?            // marker position (0…1): where usage "should" be now
    var slices: [Double] = [0, 1]   // cumulative slice boundaries
    var current: Int? = nil         // slice to highlight (derived from `elapsed` if nil)
    var showMarker: Bool = true
    var showCenter: Bool = true
    var label: String = ""
    var diameter: CGFloat = 136
    var lineWidth: CGFloat = 13
    /// When set, the ring glides between layouts (size changes) as the same ring.
    var match: (id: String, ns: Namespace.ID)? = nil
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        GeometryReader { g in
            let d = min(g.size.width, g.size.height)
            ring(diameter: d, lineWidth: lineWidth * d / diameter)
                .frame(width: g.size.width, height: g.size.height)
        }
        .modifier(MatchRing(match: match))
        .frame(width: diameter, height: diameter)
    }

    @ViewBuilder
    private func ring(diameter: CGFloat, lineWidth: CGFloat) -> some View {
        let p = min(max(percent / 100, 0), 1)
        let color = usageColor(percent)
        let n = slices.count - 1
        let segmented = n > 1
        let gap = segmented ? 0.006 : 0
        let today = current ?? elapsed.flatMap { e in (0..<n).first { slices[$0] <= e && e < slices[$0 + 1] } }

        ZStack {
            ZStack {
                ForEach(0..<n, id: \.self) { k in
                    let a = slices[k] + gap
                    let b = slices[k + 1] - gap
                    if b > a {   // zero-budget days (e.g. weekends in Weekdays mode) are skipped
                        // Track. Without the pace marker, the current slice (this hour / today)
                        // is shaded darker so you can still see where you are; with the marker
                        // that's redundant, so all slices match.
                        Circle()
                            .trim(from: a, to: b)
                            .stroke(Palette.claude.opacity(segmented && !showMarker && k == today ? 0.42
                                                           : contrast == .increased ? 0.3 : 0.16),
                                    style: StrokeStyle(lineWidth: lineWidth, lineCap: segmented ? .butt : .round))
                        // Fill
                        if p > a {
                            Circle()
                                .trim(from: a, to: min(b, p))
                                .stroke(color,
                                        style: StrokeStyle(lineWidth: lineWidth, lineCap: segmented ? .butt : .round))
                        }
                    }
                }
            }
            .rotationEffect(.degrees(-90))
            .padding(lineWidth / 2)
            .animation(Motion.reduced ? nil : .easeOut(duration: 0.6), value: percent)

            if showMarker, let elapsed {
                // "Now" marker: how far through the time window we are.
                Capsule()
                    .fill(Color.white)
                    .overlay(Capsule().strokeBorder(Color(white: 0.55), lineWidth: 0.75))
                    .frame(width: 4, height: lineWidth + 8)
                    .offset(y: -(diameter / 2 - lineWidth / 2))
                    .rotationEffect(.degrees(360 * elapsed))
                    .shadow(color: .black.opacity(0.3), radius: 1.5, y: 0.5)
            }

            if showCenter { VStack(spacing: -2) {
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text("\(Int(percent.rounded()))")
                        .font(.system(size: 32, weight: .semibold, design: .rounded))
                    Text("%")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                .monospacedDigit()
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
                    .textCase(.uppercase)
                    .tracking(0.9)
                    .foregroundStyle(.secondary)
            } }
        }
        .frame(width: diameter, height: diameter)
    }
}

private struct MatchRing: ViewModifier {
    let match: (id: String, ns: Namespace.ID)?
    func body(content: Content) -> some View {
        if let match { content.matchedGeometryEffect(id: match.id, in: match.ns) } else { content }
    }
}

struct BarRow: View {
    @Environment(\.colorSchemeContrast) private var contrast
    let label: String
    let percent: Double
    var reset: String? = nil

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 96, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.claude.opacity(contrast == .increased ? 0.3 : 0.16))
                    Capsule()
                        .fill(usageColor(percent))
                        .frame(width: max(geo.size.width * min(percent / 100, 1), 6))
                }
            }
            .frame(height: 6)
            Text("\(Int(percent.rounded()))%")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .frame(width: 32, alignment: .trailing)
            if let reset {
                Text(reset)
                    .font(.system(size: 10, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: 50, alignment: .trailing)
            }
        }
    }
}

/// Compares usage with time elapsed: "On pace", "Ahead of pace" (burning fast) or "Under pace".
struct PaceNote: View {
    let percent: Double
    let elapsed: Double?
    var short = false
    /// Two lines, always (medium widget): headline, then a smaller description.
    var stacked = false
    @Environment(\.widgetDimmed) private var dimmed

    var body: some View {
        if stacked, let elapsed {
            let diff = percent - elapsed * 100
            let d = Int(abs(diff).rounded())
            let (top, bottom, icon, color): (String, String, String, Color) =
                diff >= 3  ? ("+\(d)%", "ahead", "arrow.up.right.circle.fill", diff >= 15 ? Palette.rust : Palette.ember)
              : diff <= -3 ? ("\(d)%", "to spare", "checkmark.circle.fill", Palette.claude)
              :              ("On pace", "within 3%", "equal.circle.fill", Palette.claude)
            StackedNote(top: top, bottom: bottom, icon: icon, color: dimmed ? Color.white.opacity(0.95) : color)
                .help("Ahead of pace means you're using this limit faster than time is passing, and may hit it before it resets.")
        } else if let elapsed {
            let diff = percent - elapsed * 100
            let d = Int(abs(diff).rounded())
            let (text, icon, color): (String, String, Color) =
                diff >= 3  ? (short ? "Ahead +\(d)%" : "Ahead of pace +\(d)%", "arrow.up.right.circle.fill", diff >= 15 ? Palette.rust : Palette.ember)
              : diff <= -3 ? (short ? "\(d)% spare" : "\(d)% to spare", "checkmark.circle.fill", Palette.claude)
              :              ("On pace", "equal.circle.fill", Palette.claude)
            Label(text, systemImage: icon)
                .labelStyle(FixedIconLabelStyle())
                .font(.system(size: short ? 10 : 11, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(dimmed ? Color.white.opacity(0.95) : color)
                .lineLimit(1)
                .help("Ahead of pace means you're using this limit faster than time is passing, and may hit it before it resets.")
        }
    }
}

/// Icons sit in a fixed-width slot so stacked notes line up icon-centre to icon-centre.
struct FixedIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.frame(width: 14)
            configuration.title
        }
    }
}

/// Icon + bold headline, with a smaller description on a second line aligned under the headline.
struct StackedNote: View {
    let top: String
    let bottom: String
    let icon: String
    let color: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: icon).font(.system(size: 10, weight: .semibold)).frame(width: 12)
            VStack(alignment: .leading, spacing: 0) {
                Text(top).font(.system(size: 11, weight: .semibold))
                Text(bottom).font(.system(size: 10, weight: .medium)).opacity(0.8)
            }
        }
        .monospacedDigit()
        .foregroundStyle(color)
        .lineLimit(1)
        .fixedSize()
    }
}

// MARK: - Saved limit resets (tracked manually — the usage API doesn't expose them)

enum ResetReminder {
    /// The Nov 2026 free full reset expires Dec 10, 2026 at 2pm PT. Only used to migrate people
    /// who saved resets before the expiry became something you set yourself.
    static let promoExpiry: Double = {
        var c = DateComponents()
        c.year = 2026; c.month = 12; c.day = 10; c.hour = 14
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")
        return Calendar(identifier: .gregorian).date(from: c)!.timeIntervalSince1970
    }()

    /// One-off: before this version, an unset expiry meant the promo date. Keep that for anyone
    /// with saved resets, while it's still ahead.
    static func migrateExpiry(now: Date) {
        let d = UserDefaults.standard
        guard d.integer(forKey: "resetCount") > 0, d.object(forKey: "resetExpiry") == nil,
              now.timeIntervalSince1970 < promoExpiry else { return }
        d.set(promoExpiry, forKey: "resetExpiry")
    }
    static let settingsURL = URL(string: "https://claude.ai/settings/usage")!

    /// How long before expiry to remind, in seconds (user-editable). Default: 7 days, 1 day, 3 hours.
    static let defaultLeads = [3 * 3600, 86400, 7 * 86400]
    static var leads: [Int] {
        ((UserDefaults.standard.array(forKey: "resetReminderLeads") as? [Int]) ?? defaultLeads).sorted()
    }
    static func leadText(_ secs: Int, long: Bool = false) -> String {
        if secs % 86400 == 0 { let d = secs / 86400; return long ? "\(d) day\(d == 1 ? "" : "s")" : "\(d)d" }
        let h = secs / 3600; return long ? "\(h) hour\(h == 1 ? "" : "s")" : "\(h)h"
    }
    static var leadsSummary: String {
        let l = leads.sorted(by: >).map { leadText($0, long: true) }
        switch l.count {
        case 0: return "no reminders set"
        case 1: return l[0]
        default: return l.dropLast().joined(separator: ", ") + " and " + l.last!
        }
    }

    static var count: Int { UserDefaults.standard.integer(forKey: "resetCount") }
    /// Nil until the user sets one (then no reminders fire).
    static var expiry: Double? {
        let v = UserDefaults.standard.double(forKey: "resetExpiry")
        return v > 0 ? v : nil
    }

    static func remainingText(_ secs: TimeInterval) -> String {
        let s = Int(secs)
        if s <= 0 { return "expired" }
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(max(m, 1))m"
    }

    /// Urgency colour: Claude orange → dark orange (≤7 days) → dark red (≤1 day).
    static func color(_ remaining: TimeInterval) -> Color {
        remaining <= 86400 ? Palette.rust : remaining <= 7 * 86400 ? Palette.ember : Palette.claude
    }

    /// Sends one macOS notification as each threshold (7 days, 1 day, 3 hours) is crossed.
    static func check() {
        let d = UserDefaults.standard
        guard d.object(forKey: "resetReminders") as? Bool ?? true else { return }
        guard let exp = expiry else { return }
        let n = count
        let remaining = exp - Date().timeIntervalSince1970
        guard n > 0, remaining > 0 else { return }
        let thresholds = ResetReminder.leads   // ascending, in seconds
        guard let hit = thresholds.first(where: { remaining <= Double($0) }) else { return }
        let key = "notified-\(Int(exp))-\(hit)"
        guard !NotifiedLog.contains(key) else { return }
        NotifiedLog.record(thresholds.filter { $0 >= hit }.map { "notified-\(Int(exp))-\($0)" }, now: Date())

        Notifier.post(id: key, title: "Claude limit reset expiring",
                      body: "You have \(n) saved reset\(n == 1 ? "" : "s") expiring in \(remainingText(remaining)). Click to use it in Settings → Usage.")
    }
}

/// Chip showing saved resets and their expiry; opens the editor when clicked.
struct ResetChip: View {
    @AppStorage("resetCount") var count = 0
    @AppStorage("resetExpiry") var expiry: Double = 0   // 0 = not set
    let now: Date
    var compact = false
    var onTap: () -> Void = {}

    var body: some View {
        let noExpiry = expiry <= 0
        let remaining = noExpiry ? .infinity : expiry - now.timeIntervalSince1970
        let active = count > 0 && remaining > 0
        let color = active ? (noExpiry ? Palette.claude : ResetReminder.color(remaining)) : Color.secondary

        Button(action: onTap) {
            HStack(spacing: 5) {
                if active && remaining <= 7 * 86400 {
                    Image(systemName: "bell.badge.fill")
                        .font(.system(size: compact ? 9 : 11, weight: .bold))
                } else {
                    SessionResetGlyph()
                        .scaleEffect(compact ? 0.7 : 0.85)
                        .frame(width: compact ? 11 : 14, height: compact ? 11 : 14)
                }
                if compact {
                    Text("\(count)").monospacedDigit()
                } else if active && noExpiry {
                    Text("\(count) reset\(count == 1 ? "" : "s") saved")
                    Text("·").foregroundStyle(.secondary)
                    Text("set expiry")
                } else if active {
                    Text("\(count) reset\(count == 1 ? "" : "s") saved")
                    Text("·").foregroundStyle(.secondary)
                    Text(remaining <= 7 * 86400
                         ? "use within \(ResetReminder.remainingText(remaining))"
                         : "expires in \(ResetReminder.remainingText(remaining))")
                        .monospacedDigit()
                } else {
                    Text(count > 0 ? "Saved resets expired" : "Track saved limit resets")
                }
            }
            .font(.system(size: compact ? 10 : 11, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, compact ? 6 : 10)
            .padding(.vertical, compact ? 3 : 5)
            .background(Capsule().fill((active ? color : Color.primary).opacity(active ? 0.14 : 0.06)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(active ? "Saved limit resets. Click to edit or mark one used." : "Click to track saved limit resets.")
        .accessibilityLabel(compact ? "\(count) saved reset\(count == 1 ? "" : "s")" : "Saved limit resets")
    }
}

// MARK: - Controls

/// Toolbar glyphs share one ring size and stroke so they read as a set.
enum GlyphMetrics {
    static let size: CGFloat = 12
    static let stroke: CGFloat = 2
}

/// 5-slice ring, matching the segmented gauges.
struct SegmentGlyph: View {
    var body: some View {
        ZStack {
            ForEach(0..<5, id: \.self) { k in
                Circle()
                    .trim(from: Double(k) / 5 + 0.018, to: Double(k + 1) / 5 - 0.018)
                    .stroke(style: StrokeStyle(lineWidth: GlyphMetrics.stroke, lineCap: .butt))
            }
        }
        .rotationEffect(.degrees(-90))
        .padding(GlyphMetrics.stroke / 2)
        .frame(width: GlyphMetrics.size, height: GlyphMetrics.size)
    }
}

/// Ring with a tick across it, matching the pace marker on the gauges.
struct PaceGlyph: View {
    var body: some View {
        let r = (GlyphMetrics.size - GlyphMetrics.stroke) / 2
        ZStack {
            // Ring breaks around the tick for breathing room (gap centred on the tick at 45°).
            Circle()
                .trim(from: 0.08, to: 0.92)
                .stroke(style: StrokeStyle(lineWidth: GlyphMetrics.stroke, lineCap: .butt))
                .rotationEffect(.degrees(-45))
                .padding(GlyphMetrics.stroke / 2)
            Capsule()
                .frame(width: GlyphMetrics.stroke, height: 6)
                .offset(y: -r)
                .rotationEffect(.degrees(45))
        }
        .frame(width: GlyphMetrics.size, height: GlyphMetrics.size)
    }
}

/// Widget size on a 2×2 grid: faint empty cells, with the cells it fills drawn as one connected shape.
struct SizeGlyph: View {
    let size: WidgetSize

    var body: some View {
        let cell: CGFloat = 5, gap: CGFloat = 2, r: CGFloat = 1.3
        let span = { (n: Int) in CGFloat(n) * cell + CGFloat(n - 1) * gap }
        ZStack(alignment: .topLeading) {
            VStack(spacing: gap) {
                ForEach(0..<2, id: \.self) { row in
                    HStack(spacing: gap) {
                        ForEach(0..<2, id: \.self) { col in
                            if !(col < size.cols && row < size.rows) {
                                RoundedRectangle(cornerRadius: r, style: .continuous).opacity(0.28)
                            } else { Color.clear }
                        }
                        .frame(width: cell, height: cell)
                    }
                }
            }
            RoundedRectangle(cornerRadius: r, style: .continuous)
                .frame(width: span(size.cols), height: span(size.rows))
        }
        .frame(width: GlyphMetrics.size, height: GlyphMetrics.size)
    }
}

/// Settings gear: 8 squared teeth, solid body, large hole.
struct GearGlyph: View {
    var body: some View {
        GearShape(ringWidth: GlyphMetrics.stroke)   // same ring weight as the pace & segment glyphs
            .fill(style: FillStyle(eoFill: true))
            .frame(width: GlyphMetrics.size + 1, height: GlyphMetrics.size + 1)
    }
}

private struct IconButtonSizeKey: EnvironmentKey { static let defaultValue: CGFloat = 22 }
extension EnvironmentValues {
    /// Header button diameter (smaller in the small widget so all of them fit across 164pt).
    var iconButtonSize: CGFloat {
        get { self[IconButtonSizeKey.self] }
        set { self[IconButtonSizeKey.self] = newValue }
    }
}

struct IconButton<Glyph: View>: View {
    @Environment(\.iconButtonSize) private var side
    var active = false
    let help: String
    /// What VoiceOver reads (the icon has no text of its own).
    var label: String = ""
    let action: () -> Void
    @ViewBuilder let glyph: () -> Glyph

    var body: some View {
        Button(action: action) {
            glyph()
                .font(.system(size: 10, weight: .semibold))
                .frame(width: side, height: side)
                .foregroundStyle(active ? Palette.claude : Color.primary.opacity(0.62))   // explicit grey: shapes and SF Symbols match
                .background(Circle().fill(active ? Palette.claude.opacity(0.18) : Color.primary.opacity(0.07)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help.isEmpty ? "" : help)
        .accessibilityLabel(label.isEmpty ? help : label)
    }
}

struct ControlBar: View {
    @ObservedObject var store: UsageStore
    var showSizeToggle = true
    var showRefresh = false
    var onSettings: () -> Void = {}
    @AppStorage("menuBar") var menuBar = true
    @AppStorage("showWidget") var showWidget = true
    @AppStorage("floatOnTop") var floatOnTop = false
    @AppStorage(WidgetSize.key) var sizeRaw = WidgetSize.current.rawValue
    var size: WidgetSize { WidgetSize(rawValue: sizeRaw) ?? .large }
    var onLevelChange: (Bool) -> Void
    var onSizeChange: (Bool) -> Void

    // In-widget tooltip (macOS only shows .help tooltips for the active app, which a desktop widget rarely is).
    @State private var tip: String?
    @State private var tipTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: size == .small && showSizeToggle ? 2 : 3) {
            if showRefresh {
                IconButton(help: "Refresh now", label: "Refresh", action: { Task { await store.refresh(userInitiated: true) } }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .heavy))   // ~2pt stroke, like the custom glyphs
                }
                .disabled(store.loading)
                .opacity(store.loading ? 0.5 : 1)
                .onHover { hover($0, store.loading ? "Refreshing…" : "Refresh") }
            }
            if showSizeToggle {
                // One button for each of the other two sizes.
                ForEach(WidgetSize.allCases.filter { $0 != size }, id: \.self) { s in
                    IconButton(help: "", label: "\(s.name) size", action: {
                        WidgetSize.noteChange(from: sizeRaw, to: s.rawValue)
                        withAnimation(WidgetSize.changeAnimation) { sizeRaw = s.rawValue }
                        onSizeChange(true)
                    }) {
                        SizeGlyph(size: s)
                    }
                    .onHover { hover($0, "\(s.name) size") }
                }
            }
            IconButton(help: "", label: "Settings", action: onSettings) {
                GearGlyph()
            }
            .onHover { hover($0, "Settings") }
            if showSizeToggle {   // desktop widget only, not the menu bar popover
                IconButton(help: "", label: "Close", action: { CloseMenu.shared.show() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .heavy))
                }
                .onHover { hover($0, "Close") }
            } else if !showWidget {   // menu bar popover, widget hidden with the X: bring it back
                IconButton(active: true, help: "", label: "Show desktop widget", action: { showWidget = true }) {
                    Image(systemName: "macwindow.badge.plus")
                }
                .onHover { hover($0, "Show desktop widget") }
            }
        }
        .overlay(alignment: .topTrailing) {
            if let tip {
                Text(tip)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.regularMaterial))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.15), radius: 4, y: 1)
                    .frame(width: (size == .small && showSizeToggle) ? 136 : 210, alignment: .trailing)
                    .offset(y: 28)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
    }

    /// Show after a short pause; switch instantly when moving between buttons.
    private func hover(_ inside: Bool, _ text: String) {
        tipTask?.cancel()
        if inside {
            if tip != nil { tip = text; return }
            tipTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(450))
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.12)) { tip = text }
            }
        } else {
            tipTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(80))   // bridge the gap between adjacent buttons
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.1)) { tip = nil }
            }
        }
    }
}

/// The widget's X: hide just the desktop widget (the menu bar gauge stays) or quit.
@MainActor
final class CloseMenu: NSObject {
    static let shared = CloseMenu()

    func show() {
        let menu = NSMenu()
        let hide = NSMenuItem(title: "Hide Widget (Keep Menu Bar)", action: #selector(hideWidget), keyEquivalent: "")
        hide.target = self
        hide.image = NSImage(systemSymbolName: "menubar.rectangle", accessibilityDescription: nil)
        let quit = NSMenuItem(title: "Quit Claude Usage", action: #selector(quit), keyEquivalent: "")
        quit.target = self
        quit.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
        menu.addItem(hide)
        menu.addItem(quit)
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    @objc private func hideWidget() { AppMenu.hideWidget() }   // keeps the menu bar gauge on

    @objc private func quit() { NSApp.terminate(nil) }
}

// MARK: - Shared widget state and commands

/// Reduce Motion / Increase Contrast, read live from the system.
enum Motion {
    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
}

/// State the desktop widget's SwiftUI view and its window share.
@MainActor
final class WidgetState: ObservableObject {
    static let shared = WidgetState()
    /// Settings (or saved resets) opened from the small or medium widget: shown at large size for
    /// now. The saved `widgetSize` and `widgetOrigin` don't change.
    @Published var expanded = false
}

/// Menu commands (right-click menu, menu bar item) for a widget view to carry out.
enum WidgetCommand {
    static let name = Notification.Name("ClaudeUsage.widgetCommand")
    enum Target: String { case widget, popover }
    case open(Panel, Target)
    case setSize(WidgetSize)
    case closePanels

    @MainActor func send() { NotificationCenter.default.post(name: Self.name, object: nil, userInfo: ["cmd": Box(self)]) }
    final class Box { let cmd: WidgetCommand; init(_ c: WidgetCommand) { cmd = c } }
    static func from(_ n: Notification) -> WidgetCommand? { (n.userInfo?["cmd"] as? Box)?.cmd }
}

// MARK: - Widget

struct WidgetView: View {
    @ObservedObject var store: UsageStore
    @AppStorage("showPaceMarker") var showPaceMarker = true
    @AppStorage("segmentedRings") var segmentedRings = true
    @AppStorage(WidgetSize.key) var sizeRaw = WidgetSize.current.rawValue
    @AppStorage("resetCount") var resetCount = 0
    @State private var hovering = false
    @State private var stack: [Panel] = []
    @Namespace private var rings
    @AppStorage("showScoped") var showScoped = true
    @AppStorage("showPaceNote") var showPaceNote = true
    @AppStorage("showForecast") var showForecast = true
    /// Used by the menu bar popover, which always shows the large layout.
    var forceLarge = false
    @ObservedObject private var state = WidgetState.shared
    /// The size the user chose (and the one restored after settings close).
    var savedSize: WidgetSize { WidgetSize(rawValue: sizeRaw) ?? .large }
    /// The size shown: always large while settings are open.
    var size: WidgetSize { forceLarge || state.expanded ? .large : savedSize }
    @AppStorage("shrinkDown") var shrinkDown = false
    @AppStorage("shrinkRight") var shrinkRight = false
    /// Content stays pinned to the edges that don't move while the window resizes.
    var contentAnchor: Alignment {
        switch (shrinkDown, shrinkRight) {
        case (false, false): .topLeading
        case (false, true): .topTrailing
        case (true, false): .bottomLeading
        case (true, true): .bottomTrailing
        }
    }
    var dimmedNow: Bool { store.dimmed && !forceLarge && stack.isEmpty }
    var onLevelChange: (Bool) -> Void
    var onSizeChange: (Bool) -> Void
    /// Grow to large for settings (true), or go back to the saved size (false).
    var onExpand: (Bool) -> Void = { _ in }

    /// Header buttons appear only while the pointer is over the widget (always in the menu bar popover).
    var showControls: Bool { forceLarge || hovering }

    var controls: ControlBar {
        ControlBar(store: store, showSizeToggle: !forceLarge, showRefresh: true, onSettings: { open(.settings) },
                   onLevelChange: onLevelChange, onSizeChange: onSizeChange)
    }

    var body: some View {
        Group {
            if let p = stack.last {
                panelView(p)
                    .padding(padding(size))
                    .frame(width: Grid.inner(size).width, height: Grid.inner(size).height)
            } else {
                // Layouts overlay each other (never stack) so that while one fades out and the
                // next fades in, nothing gets pushed around; each keeps its own size and padding.
                ZStack(alignment: contentAnchor) {
                    switch size {
                    case .small: layout(.small)
                    case .medium: layout(.medium)
                    case .large: layout(.large)
                    }
                }
            }
        }
        // minWidth/minHeight 0: never report a size bigger than the glass. Otherwise, while the
        // glass is still growing, the bigger layout gets centered in it and jumps.
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: contentAnchor)
        .overlay(alignment: .topTrailing) {
            // Small widget: controls float in on hover, from the top-right corner like the
            // medium and large header.
            if size == .small && hovering && stack.isEmpty {
                controls
                    .environment(\.iconButtonSize, 19)
                    .padding(3)
                    .background(Capsule().fill(.regularMaterial))
                    // Same buttons as the medium/large header: glide there when the size changes.
                    .matchedGeometryEffect(id: "controls", in: rings)
                    .padding(.top, 6)
                    .padding(.trailing, 6)
                    .transition(.opacity)
            }
        }
        .onHover { h in withAnimation(Motion.reduced ? nil : .easeOut(duration: 0.15)) { hovering = h } }
        // Like native desktop widgets: when you're working in an app, fade to a translucent
        // monochrome look; full colour returns when you click the desktop.
        .animation(WidgetSize.changeAnimation, value: size)
        .environment(\.widgetDimmed, dimmedNow)
        .compositingGroup()
        .saturation(dimmedNow ? 0 : 1)
        .brightness(dimmedNow ? 0.32 : 0)
        .opacity(dimmedNow ? 0.8 : 1)   // soft, slightly see-through text like native dimmed widgets
        .overlay {
            // Native dimmed widgets have a crisp light rim and a soft glow just inside the edge.
            if dimmedNow {
                ZStack {
                    RoundedRectangle(cornerRadius: Grid.cornerRadius, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 7)
                        .blur(radius: 6)
                    RoundedRectangle(cornerRadius: Grid.cornerRadius, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [.white.opacity(0.45), .white.opacity(0.2), .white.opacity(0.35)],
                                                     startPoint: .topLeading, endPoint: .bottomTrailing),
                                      lineWidth: 1)
                }
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        .animation(Motion.reduced ? nil : .easeInOut(duration: 0.35), value: dimmedNow)
        // Clicking another window, app or the desktop means you're done with settings: back to
        // the rings (and the saved size). Opening a panel always makes this app active first.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            guard !forceLarge, !stack.isEmpty else { return }
            withAnimation(Self.panelAnimation) { stack.removeAll() }
            if state.expanded { onExpand(false) }
        }
        .onReceive(NotificationCenter.default.publisher(for: WidgetCommand.name)) { n in
            guard let cmd = WidgetCommand.from(n) else { return }
            switch cmd {
            case .open(let p, let target):
                guard (target == .popover) == forceLarge else { return }
                stack.removeAll()
                open(p)
            case .setSize(let s):
                guard !forceLarge else { return }
                WidgetSize.noteChange(from: sizeRaw, to: s.rawValue)
                withAnimation(WidgetSize.changeAnimation) { sizeRaw = s.rawValue }
                onSizeChange(true)
            case .closePanels:
                guard !forceLarge else { return }
                stack.removeAll()
            }
        }
    }

    @ViewBuilder
    func content(_ u: Usage) -> some View {
        let sReset = parseDate(u.five_hour?.resets_at)
        let wReset = parseDate(u.seven_day?.resets_at)
        let sElapsed = elapsedFraction(resetsAt: sReset, duration: 5 * 3600, now: store.now)
        let budget = WeekBudget(resetsAt: wReset, now: store.now)
        let wElapsed = budget?.expected
        let weekly = u.seven_day?.utilization ?? 0
        let session = u.five_hour?.utilization ?? 0

        // Fixed gap (never reacts to status text). When the model limit bar is hidden, push the rings
        // down by half that bar's space so the empty space above and below evens out.
        let hasScoped = showScoped && (u.limits ?? []).contains { $0.kind == "weekly_scoped" }
        Color.clear.frame(height: hasScoped ? 10 : 22)
        HStack(alignment: .top) {
            VStack(spacing: 5) {
                RingGauge(percent: session, elapsed: sElapsed, slices: segmentedRings ? uniformSlices(5) : [0, 1],
                          showMarker: showPaceMarker, label: "Session", match: ("session", rings))
                    .help("Each slice is one hour of the 5-hour session. The white tick marks now.")
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Session usage")
                    .accessibilityValue(ringValue(session, reset: sReset, elapsed: sElapsed, session: true))
                Text(sessionResetText(sReset, now: store.now)).caption()
                // Left-aligned together, icons on one centre line.
                VStack(alignment: .leading, spacing: 5) {
                    if showPaceNote { PaceNote(percent: session, elapsed: sElapsed) }
                    if showForecast && aheadOfPace(session, sElapsed) {
                        ForecastNote(hit: Forecast.hitTime(util: session, resetsAt: sReset, duration: 5 * 3600,
                                                           now: store.now, useRecent: true), now: store.now)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            VStack(spacing: 5) {
                RingGauge(percent: weekly, elapsed: wElapsed,
                          slices: segmentedRings ? (budget?.boundaries ?? uniformSlices(7)) : [0, 1],
                          current: budget?.current, showMarker: showPaceMarker, label: "Weekly", match: ("weekly", rings))
                    .help("Each slice is one day's budget. The white tick marks where you should be by now.")
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Weekly usage")
                    .accessibilityValue(ringValue(weekly, reset: wReset, elapsed: wElapsed, session: false))
                Text(resetText(wReset, now: store.now)).caption()
                VStack(alignment: .leading, spacing: 5) {
                    if showPaceNote { PaceNote(percent: weekly, elapsed: wElapsed) }
                    if showForecast && aheadOfPace(weekly, wElapsed) {
                        ForecastNote(hit: Forecast.hitTime(util: weekly, resetsAt: wReset, duration: 7 * 86400,
                                                           now: store.now, useRecent: false), now: store.now)
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }

        let scoped = showScoped ? (u.limits ?? []).filter { $0.kind == "weekly_scoped" } : []
        if !scoped.isEmpty {
            Spacer(minLength: 10)
            VStack(spacing: 6) {
                ForEach(Array(scoped.enumerated()), id: \.offset) { _, l in
                    BarRow(label: "\(l.scope?.model?.display_name ?? "Model") weekly",
                           percent: l.percent ?? 0,
                           reset: resetText(parseDate(l.resets_at), now: store.now)
                               .replacingOccurrences(of: "resets in ", with: "↻ "))
                        .help("\(l.scope?.model?.display_name ?? "Model") has its own weekly limit, \(resetText(parseDate(l.resets_at), now: store.now)).")
                }
            }
            .padding(.horizontal, 2)
        }
        Spacer(minLength: 10)
        ResetChip(now: store.now, onTap: { open(.resets) }).frame(maxWidth: .infinity)
        if let err = store.error {
            Spacer(minLength: 6)
            errorLabel(err)
        }
    }

    /// Small widget: weekly ring on the outside, session ring nested inside.
    @ViewBuilder
    func compactContent(_ u: Usage) -> some View {
        let sReset = parseDate(u.five_hour?.resets_at)
        let wReset = parseDate(u.seven_day?.resets_at)
        let sElapsed = elapsedFraction(resetsAt: sReset, duration: 5 * 3600, now: store.now)
        let budget = WeekBudget(resetsAt: wReset, now: store.now)
        let wElapsed = budget?.expected
        let session = u.five_hour?.utilization ?? 0
        let weekly = u.seven_day?.utilization ?? 0
        let outer: CGFloat = 118, weeklyLine: CGFloat = 5, sessionLine: CGFloat = 11

        Spacer(minLength: 0)
        ZStack {
            RingGauge(percent: weekly, elapsed: wElapsed,
                      slices: segmentedRings ? (budget?.boundaries ?? uniformSlices(7)) : [0, 1],
                      current: budget?.current,
                      showMarker: showPaceMarker, showCenter: false, diameter: outer, lineWidth: weeklyLine,
                      match: ("weekly", rings))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Weekly usage")
                .accessibilityValue(ringValue(weekly, reset: wReset, elapsed: wElapsed, session: false))
            RingGauge(percent: session, elapsed: sElapsed, slices: segmentedRings ? uniformSlices(5) : [0, 1],
                      showMarker: showPaceMarker, showCenter: false,
                      diameter: outer - 2 * (weeklyLine + 5), lineWidth: sessionLine,
                      match: ("session", rings))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Session usage")
                .accessibilityValue(ringValue(session, reset: sReset, elapsed: sElapsed, session: true))
            VStack(spacing: -1) {
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text("\(Int(session.rounded()))")
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                    Text("%")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                Text("WK \(Int(weekly.rounded()))%")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .tracking(0.5)
                    .foregroundStyle(usageColor(weekly))
            }
            .monospacedDigit()
            .accessibilityHidden(true)   // the rings say it
        }
        .padding(.top, 6)   // sit the rings a touch lower in the small widget
        .frame(maxWidth: .infinity)
        .help("Outer ring: weekly limit (7 days). Inner ring: 5-hour session. White ticks mark now.")
        .overlay(alignment: .topTrailing) {
            if let p = store.problem {
                // Something's wrong: a warning plus how old the numbers are.
                HStack(spacing: 2) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    if let age = ageText(store.lastUpdated, now: store.now) { Text(age) }
                }
                .font(.system(size: 10, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(dimmedNow ? AnyShapeStyle(Color.white.opacity(0.95)) : AnyShapeStyle(Palette.rust))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.primary.opacity(0.07)))
                .offset(x: 2, y: -4)
                .help("\(p.short). \(p.long)")
            } else if let age = ageText(store.lastUpdated, now: store.now),
               store.notice != nil || store.now.timeIntervalSince(store.lastUpdated ?? store.now) > 150 {
                Text(age)
                    .font(.system(size: 10, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))
                    .offset(x: 2, y: -4)
                    .help(store.notice ?? "Last updated \(age)")
            }
        }
        .overlay(alignment: .topLeading) {
            if resetCount > 0 { ResetChip(now: store.now, compact: true, onTap: { open(.resets) }).offset(x: -2, y: -4) }
        }
        Spacer(minLength: 4)
        HStack {
            if showForecast, aheadOfPace(session, sElapsed),
               let hit = Forecast.hitTime(util: session, resetsAt: sReset, duration: 5 * 3600,
                                          now: store.now, useRecent: true) {
                ForecastNote(hit: hit, now: store.now, short: true)
            } else if showPaceNote {
                PaceNote(percent: session, elapsed: sElapsed, short: true)
            }
            Spacer(minLength: 0)
            HStack(spacing: 2) {
                SessionResetGlyph().scaleEffect(0.62).frame(width: 10, height: 10)
                Text(sReset == nil ? "starts on use" : compactReset(sReset))
            }
            .font(.system(size: 10, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(dimmedNow ? AnyShapeStyle(Color.white.opacity(0.85)) : AnyShapeStyle(.secondary))
            .help(sReset == nil ? "The 5-hour session starts with your next message" : resetText(sReset, now: store.now).capitalized(with: nil) + " (5-hour session)")
        }
        .font(.system(size: 10))
    }

    func padding(_ s: WidgetSize) -> CGFloat { s == .small ? 10 : s == .medium ? 12 : 16 }

    func layout(_ s: WidgetSize) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if s == .large { header.zIndex(1) }
            if let u = store.usage {
                switch s {
                case .small: compactContent(u)
                case .medium: mediumContent(u)
                case .large: content(u)
                }
            } else if let err = store.error ?? store.notice {
                Spacer()
                errorLabel(err)
                Spacer()
            } else {
                Spacer()
                ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                Spacer()
            }
        }
        .padding(padding(s))
        .frame(width: Grid.inner(s).width, height: Grid.inner(s).height, alignment: .top)
        .transition(.opacity)
    }

    /// Medium widget (2×1, landscape): the two rings side by side, each with its details beside it.
    @ViewBuilder
    func mediumContent(_ u: Usage) -> some View {
        let sReset = parseDate(u.five_hour?.resets_at)
        let wReset = parseDate(u.seven_day?.resets_at)
        let sElapsed = elapsedFraction(resetsAt: sReset, duration: 5 * 3600, now: store.now)
        let budget = WeekBudget(resetsAt: wReset, now: store.now)
        let wElapsed = budget?.expected
        let session = u.five_hour?.utilization ?? 0
        let weekly = u.seven_day?.utilization ?? 0
        let scoped = showScoped ? (u.limits ?? []).filter { $0.kind == "weekly_scoped" } : []

        // Brand and status on the left (as in the large widget), controls on the right.
        HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    SegmentGlyph()
                        .foregroundStyle(Palette.claude)
                        .scaleEffect(1.2)
                        .frame(width: 15, height: 15)
                    Text("Claude Usage")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .fixedSize()
                        .overlay(alignment: .topTrailing) { UpdateDot().offset(x: 16.5, y: -9.5) }
                }
                .matchedGeometryEffect(id: "brand", in: rings)
                // One reserved status line so the rings never shift.
                let n = store.error == nil ? store.notice : nil
                Group {
                    if let p = store.problem {
                        Label(p.short, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(dimmedNow ? AnyShapeStyle(Color.white.opacity(0.95)) : AnyShapeStyle(Palette.rust))
                            .help(p.long)
                    } else if n != nil {
                        Label("Updates paused", systemImage: "pause.circle")
                            .foregroundStyle(.secondary)
                            .help("Anthropic's usage API asked us to slow down (or you're offline). The numbers shown are from the last successful update.")
                    } else {
                        Text(ageText(store.lastUpdated, now: store.now).map { "Updated \($0)" } ?? " ")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: 10, weight: .medium))
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()   // never truncate; the spacer gives way instead
            }
            .layoutPriority(1)
            Spacer(minLength: 4)
            // The chip gives way to the buttons on hover.
            if resetCount > 0 {
                ResetChip(now: store.now, compact: true, onTap: { open(.resets) })
                    .opacity(showControls ? 0 : 1)
                    .allowsHitTesting(!showControls)
            }
        }
        // Buttons float over the row instead of taking room in it: there isn't space for the
        // brand, the chip and all the buttons, and an over-wide row shifts the whole layout left.
        .overlay(alignment: .topTrailing) {
            controls.opacity(showControls ? 1 : 0)
                .allowsHitTesting(showControls)
                .matchedGeometryEffect(id: "controls", in: rings)
        }
        .zIndex(1)   // keep the hover labels above the rings
        Spacer(minLength: 4)
        // Each block hugs its content and the spare width is shared equally (left edge, between,
        // right edge), so the pair sits centred instead of leaving a gap on the right.
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            mediumBlock(title: "Session", percent: session, elapsed: sElapsed, reset: sReset,
                        slices: segmentedRings ? uniformSlices(5) : [0, 1], current: nil,
                        forecast: showForecast && aheadOfPace(session, sElapsed)
                            ? Forecast.hitTime(util: session, resetsAt: sReset, duration: 5 * 3600,
                                               now: store.now, useRecent: true) : nil)
                .help("Each slice is one hour of the 5-hour session. The white tick marks now.")
            Spacer(minLength: 6)
            mediumBlock(title: "Weekly", percent: weekly, elapsed: wElapsed, reset: wReset,
                        slices: segmentedRings ? (budget?.boundaries ?? uniformSlices(7)) : [0, 1],
                        current: budget?.current,
                        forecast: showForecast && aheadOfPace(weekly, wElapsed)
                            ? Forecast.hitTime(util: weekly, resetsAt: wReset, duration: 7 * 86400,
                                               now: store.now, useRecent: false) : nil)
                .help("Each slice is one day's budget. The white tick marks where you should be by now.")
            Spacer(minLength: 0)
        }
        Spacer(minLength: 4)
        if let l = scoped.first {
            BarRow(label: "\(l.scope?.model?.display_name ?? "Model") weekly",
                   percent: l.percent ?? 0,
                   reset: resetText(parseDate(l.resets_at), now: store.now)
                       .replacingOccurrences(of: "resets in ", with: "↻ "))
                .padding(.horizontal, 2)
        }
    }

    func mediumBlock(title: String, percent: Double, elapsed: Double?, reset: Date?,
                     slices: [Double], current: Int?, forecast: Date?) -> some View {
        HStack(spacing: 8) {
            ZStack {
                RingGauge(percent: percent, elapsed: elapsed, slices: slices, current: current,
                          showMarker: showPaceMarker, showCenter: false, diameter: 80, lineWidth: 10,
                          match: (title.lowercased(), rings))
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text("\(Int(percent.rounded()))")
                        .font(.system(size: 21, weight: .semibold, design: .rounded))
                    Text("%")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                .monospacedDigit()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(title) usage")
            .accessibilityValue(ringValue(percent, reset: reset, elapsed: elapsed, session: title == "Session"))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .textCase(.uppercase)
                    .tracking(0.9)
                    .foregroundStyle(.secondary)
                Text(reset == nil && title == "Session" ? "starts when\nyou use Claude" : compactReset(reset))
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(dimmedNow ? AnyShapeStyle(Color.white.opacity(0.85)) : AnyShapeStyle(.secondary))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if forecast != nil {
                    ForecastNote(hit: forecast, now: store.now, stacked: true)
                } else if showPaceNote {
                    PaceNote(percent: percent, elapsed: elapsed, stacked: true)
                }
            }
            .fixedSize()   // natural width, so the row can centre the pair
        }
    }

    static var panelAnimation: Animation? { Motion.reduced ? nil : .easeOut(duration: 0.2) }

    /// Settings and saved resets only render at large size: a small or medium widget grows
    /// (from its Resize direction corner) with the panel fading in as it goes, so the large
    /// rings never flash up in between. At any size, a size picked while a panel is open
    /// applies when it closes.
    func open(_ p: Panel) {
        if p == .settings { UserDefaults.standard.set(0, forKey: "settingsTab") }   // always start on the first tab (Rings)
        NSApp.activate()   // lets the date field take keyboard input
        if !forceLarge && !state.expanded { onExpand(true) }
        withAnimation(Self.panelAnimation) { stack.append(p) }
    }

    var nav: Nav {
        Nav(push: { p in withAnimation(Self.panelAnimation) { stack.append(p) } },
            pop: {
                withAnimation(Self.panelAnimation) { _ = stack.popLast() }
                if stack.isEmpty && state.expanded { onExpand(false) }   // back to the saved size and spot
            })
    }

    @ViewBuilder
    func panelView(_ p: Panel) -> some View {
        switch p {
        case .settings:
            SettingsPanel(store: store, nav: nav, allowSize: !forceLarge,
                          onLevelChange: onLevelChange, onSizeChange: onSizeChange)
        case .appearance:
            AppearancePanel(nav: nav, allowSize: !forceLarge,
                            onLevelChange: onLevelChange, onSizeChange: onSizeChange)
        case .alerts:
            AlertsPanel(nav: nav)
        case .data:
            DataPanel(store: store, nav: nav)
        case .resets:
            ResetPanel(now: store.now, nav: nav)
        case .about:
            AboutPanel(nav: nav)
        }
    }

    /// VoiceOver: "11 percent, resets in 3 hours 33 minutes, 18 percent to spare".
    func ringValue(_ percent: Double, reset: Date?, elapsed: Double?, session: Bool) -> String {
        var parts = ["\(Int(percent.rounded())) percent"]
        if let reset {
            let f = DateComponentsFormatter()
            f.unitsStyle = .full
            f.allowedUnits = [.day, .hour, .minute]
            f.maximumUnitCount = 2
            let left = max(reset.timeIntervalSince(store.now), 0)
            parts.append(left > 0 ? "resets in \(f.string(from: max(left, 60)) ?? "")" : "resetting")
        } else if session {
            parts.append("starts when you use Claude")
        }
        if let elapsed {
            let diff = percent - elapsed * 100, d = Int(abs(diff).rounded())
            parts.append(diff >= 3 ? "\(d) percent ahead of pace" : diff <= -3 ? "\(d) percent to spare" : "on pace")
        }
        return parts.joined(separator: ", ")
    }

    func compactReset(_ d: Date?) -> String {
        resetText(d, now: store.now).replacingOccurrences(of: "resets in ", with: "in ")
    }

    func errorLabel(_ err: String) -> some View {
        Label(err, systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 11))
            .foregroundStyle(Palette.rust)
            .fixedSize(horizontal: false, vertical: true)
    }

    var header: some View {
        HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    SegmentGlyph()   // the app's 5-slice ring mark
                        .foregroundStyle(Palette.claude)
                        .scaleEffect(1.2)
                        .frame(width: 15, height: 15)
                    Text("Claude Usage")
                        .font(.system(size: 13, weight: .semibold))
                        .overlay(alignment: .topTrailing) { UpdateDot().offset(x: 16.5, y: -9.5) }
                    if store.loading { ProgressView().controlSize(.mini) }
                }
                .matchedGeometryEffect(id: "brand", in: rings)
                HStack(spacing: 5) {
                    // Always present (blank if unknown) so the header height never changes.
                    if let age = ageText(store.lastUpdated, now: store.now) ?? Optional(" ") {
                        Text(age == " " ? " " : "Updated \(age)")
                            .font(.system(size: 10, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .help(store.lastUpdated.map { "Last fetched at \($0.formatted(date: .omitted, time: .shortened))" } ?? "")
                    }
                }
                // Paused / offline notice sits right under "Updated …". Its row is always reserved
                // (invisible when there's nothing to say) so the rings never shift up or down.
                let n = store.error == nil ? store.notice : nil
                Label(n ?? "Updates paused", systemImage: "pause.circle")
                        .font(.system(size: 10))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .opacity(n == nil ? 0 : 1)
                        .help("Anthropic's usage API asked us to slow down (or you're offline). The numbers shown are from the last successful update.")
            }
            Spacer()
        }
        .overlay(alignment: .topTrailing) {   // never widens the layout (see the medium header)
            controls.opacity(showControls ? 1 : 0)
                .allowsHitTesting(showControls)
                .matchedGeometryEffect(id: "controls", in: rings)
        }
    }
}

/// Small inline ↻ next to "Updated …".
struct RefreshButton: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        Button { Task { await store.refresh(userInitiated: true) } } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 9, weight: .bold))
                .frame(width: 16, height: 16)
                .foregroundStyle(Color.primary.opacity(0.62))
                .background(Circle().fill(Color.primary.opacity(0.07)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(store.loading)
        .opacity(store.loading ? 0.4 : 1)
        .help("Refresh now")
        .accessibilityLabel("Refresh")
    }
}

/// Secondary caption that turns near-white when the widget is faded.
struct CaptionStyle: ViewModifier {
    @Environment(\.widgetDimmed) private var dimmed
    func body(content: Content) -> some View {
        content
            .font(.system(size: 11, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(dimmed ? AnyShapeStyle(Color.white.opacity(0.85)) : AnyShapeStyle(.secondary))
    }
}

extension Text {
    func caption() -> some View { modifier(CaptionStyle()) }
}

// MARK: - macOS desktop widget grid
//
// Native desktop widgets use 180pt cells, 16pt in from whichever screen edge they're near
// and flush with each other; each widget is inset 8pt inside its cells (small = 164×164pt,
// medium = 344×164pt, large = 344×344pt). The widget snaps the same way, avoiding
// cells already taken by native widgets (read from Notification Center's placement data).

/// Widget sizes, matching macOS: small (1×1), medium (2×1, landscape) and large (2×2).
enum WidgetSize: Int, CaseIterable {
    case small, medium, large
    static let key = "widgetSize"
    /// Shared by the glass resize (AppKit) and the ring move (SwiftUI) so they stay in step.
    static let duration = 0.34
    static let curve = (0.32, 0.72, 0.0, 1.0)   // gentle ease-out
    static let animation = Animation.timingCurve(curve.0, curve.1, curve.2, curve.3, duration: duration)
    /// When growing, the rings wait a beat so the glass has room for them before they move in.
    static let growDelay = 0.035
    private(set) static var lastChangeGrew = false
    /// nil with Reduce Motion on: sizes (and settings growing to large) switch without animating.
    static var changeAnimation: Animation? {
        Motion.reduced ? nil : lastChangeGrew ? animation.delay(growDelay) : animation
    }
    /// Call before changing size so the ring animation knows which way it's going.
    static func noteChange(from old: Int, to new: Int) { lastChangeGrew = new > old }
    var cols: Int { self == .small ? 1 : 2 }
    var rows: Int { self == .large ? 2 : 1 }
    var name: String { ["Small", "Medium", "Large"][rawValue] }

    static var current: WidgetSize {
        let d = UserDefaults.standard
        if d.object(forKey: key) == nil {   // migrate the old small/large switch
            return d.bool(forKey: "compact") ? .small : .large
        }
        return WidgetSize(rawValue: d.integer(forKey: key)) ?? .large
    }
}

enum Grid {
    static let pitch: CGFloat = 180
    static let margin: CGFloat = 16
    static let inset: CGFloat = 8
    static let cornerRadius: CGFloat = 26   // measured from native Tahoe desktop widgets (same at every size)
    static func outerSize(_ span: Int) -> CGFloat { pitch * CGFloat(span) }        // 180 / 360
    static func widgetSize(_ span: Int) -> CGFloat { outerSize(span) - inset * 2 }  // 164 / 344
    static func outer(_ s: WidgetSize) -> CGSize { CGSize(width: outerSize(s.cols), height: outerSize(s.rows)) }
    static func inner(_ s: WidgetSize) -> CGSize { CGSize(width: widgetSize(s.cols), height: widgetSize(s.rows)) }

    /// Top-right slot: where a new widget starts.
    static func topRight(size s: WidgetSize, in v: NSRect) -> NSRect {
        let o = outer(s)
        return NSRect(x: v.maxX - margin - o.width, y: v.maxY - margin - o.height, width: o.width, height: o.height)
    }

    /// Native desktop widgets' cells, in screen (AppKit) coordinates. Each native widget is a
    /// window owned by Notification Center at a desktop level, framed exactly on its grid cells
    /// (180pt per cell), so the public window list says where they all are. Unlike Notification
    /// Center's own settings (kept in a protected app container: reading them can stall on the
    /// "access data from other apps" prompt), window positions need no permission and are instant.
    static func nativeWidgetRects() -> [NSRect] {
        guard let nc = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui")
                .first?.processIdentifier,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]],
              let primary = NSScreen.screens.first?.frame else { return [] }
        let isCells = { (v: CGFloat) in
            let n = (v / pitch).rounded()
            return n >= 1 && n <= 4 && abs(v - n * pitch) < 1
        }
        return list.compactMap { w -> NSRect? in
            guard (w[kCGWindowOwnerPID as String] as? Int32) == nc,
                  let layer = w[kCGWindowLayer as String] as? Int, layer < 0,   // desktop levels only
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let y = b["Y"], let width = b["Width"], let height = b["Height"],
                  isCells(width), isCells(height) else { return nil }
            // The window list measures from the top-left of the main screen, AppKit from its bottom-left.
            return NSRect(x: x, y: primary.maxY - y - height, width: width, height: height)
        }
    }

    /// Kept so callers can ask for a fresh look: the window list is read live, so this just runs `done`.
    static func refreshPlacement(then done: @escaping () -> Void = {}) {
        DispatchQueue.main.async { done() }
    }

    private static func lattice(_ ref: CGFloat, len: CGFloat, lo: CGFloat, hi: CGFloat) -> [CGFloat] {
        gridLattice(ref, len: len, lo: lo, hi: hi, pitch: pitch).map { CGFloat($0) }
    }

    /// Nearest free slot for this widget size to `frame`'s origin on the given screen.
    /// Native widgets snap to whichever screen edge they're near (16pt in) and to each other,
    /// not to one grid from the top-left, so the slots follow every edge and every native group.
    static func snappedFrame(near frame: NSRect, size s: WidgetSize, on screen: NSScreen) -> NSRect {
        let v = screen.visibleFrame
        let o = outer(s)
        let taken = nativeWidgetRects().filter { $0.intersects(v) }
        let lo = (x: v.minX + margin, y: v.minY + margin), hi = (x: v.maxX - margin, y: v.maxY - margin)

        // Reference left edges and top edges (AppKit y, so a top edge is a maxY): the screen's
        // edges, and the grid each native widget sits on.
        let edgeX: [CGFloat] = [lo.x, hi.x - o.width], edgeTop: [CGFloat] = [hi.y, lo.y + o.height]
        let groupX = taken.map { $0.minX }, groupTop = taken.map { $0.maxY }   // every native widget's own grid
        func xsFrom(_ refs: [CGFloat]) -> Set<Double> {
            Set(refs.flatMap { gridLattice(Double($0), len: Double(o.width), lo: Double(lo.x), hi: Double(hi.x), pitch: Double(pitch)) }.map { $0.rounded() })
        }
        func ysFrom(_ tops: [CGFloat]) -> Set<Double> {
            Set(tops.flatMap { gridLattice(Double($0 - o.height), len: Double(o.height), lo: Double(lo.y), hi: Double(hi.y), pitch: Double(pitch)) }.map { $0.rounded() })
        }
        let alignedXs = xsFrom(groupX), alignedYs = ysFrom(groupTop)
        let xs = xsFrom(edgeX).union(alignedXs), ys = ysFrom(edgeTop).union(alignedYs)
        let slot = bestSlot(near: (Double(frame.minX), Double(frame.minY)), xs: Array(xs), ys: Array(ys),
                            w: Double(o.width), h: Double(o.height),
                            taken: taken.map { Slot(x: $0.minX, y: $0.minY, w: $0.width, h: $0.height) },
                            alignedXs: alignedXs, alignedYs: alignedYs, pitch: Double(pitch))
        return slot.map { NSRect(x: $0.x, y: $0.y, width: $0.w, height: $0.h) } ?? frame
    }
}

// MARK: - Window / app

final class WidgetWindow: NSWindow {
    var onDragEnd: (() -> Void)?
    /// The right-click / Control-click menu, built fresh each time so it shows the current state.
    var contextMenu: (() -> NSMenu)?
    /// Off while settings are open at the temporary large size.
    var draggable = true
    private var dragStart: NSPoint?
    private var originStart: NSPoint = .zero
    private var dragged = false

    override var canBecomeKey: Bool { true }

    // Manual dragging so we know exactly when the drag ends and can snap to the grid.
    override func sendEvent(_ e: NSEvent) {
        let controlClick = e.type == .leftMouseDown && e.modifierFlags.contains(.control)
        if (e.type == .rightMouseDown || controlClick), let menu = contextMenu?(), let view = contentView {
            NSMenu.popUpContextMenu(menu, with: e, for: view)
            return
        }
        switch e.type {
        case .leftMouseDown:
            guard draggable else { break }
            dragStart = NSEvent.mouseLocation
            originStart = frame.origin
            dragged = false
        case .leftMouseDragged:
            if let s = dragStart {
                let p = NSEvent.mouseLocation
                if !dragged && hypot(p.x - s.x, p.y - s.y) < 4 { break }   // tiny jitter = still a click
                setFrameOrigin(NSPoint(x: originStart.x + p.x - s.x, y: originStart.y + p.y - s.y))
                dragged = true
                return
            }
        case .leftMouseUp:
            if dragged { onDragEnd?() }
            dragStart = nil
            dragged = false
        default:
            break
        }
        super.sendEvent(e)
    }
}

/// Lets buttons respond to the first click even though the widget never becomes the active app.
final class ClickThroughHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }
    func userNotificationCenter(_ c: UNUserNotificationCenter, didReceive r: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        NSWorkspace.shared.open(ResetReminder.settingsURL)
        done()
    }

    var window: WidgetWindow!
    var menuBar: MenuBarController?
    private var themeCache: Int?
    private var dimCache: Bool?
    static let glassTint = NSColor(red: 0.85, green: 0.47, blue: 0.34, alpha: 0.10)   // faint Claude-orange tint

    /// Widget style, mirroring macOS: 0 = Automatic (fade unless the desktop is focused),
    /// 1 = always full colour, 2 = always monochrome.
    func updateFocus() {
        let style = UserDefaults.standard.integer(forKey: "widgetStyle")
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let desktopFocused = front == "com.apple.finder" || front == Bundle.main.bundleIdentifier
        let dim = style == 2 || (style == 0 && !desktopFocused)
        guard dim != dimCache, glass != nil else { return }
        dimCache = dim
        MainActor.assumeIsolated { store.dimmed = dim }
        glass.style = dim ? .clear : .regular
        glass.tintColor = dim ? NSColor.white.withAlphaComponent(0.07) : Self.glassTint   // dimmed: a touch frostier
        window.appearance = dim ? NSAppearance(named: .darkAqua) : nil   // white text, like native dimmed widgets
    }

    /// Auto / Light / Dark — applied app-wide so the widget and menu bar popover match.
    func applyTheme() {
        let t = UserDefaults.standard.integer(forKey: "theme")
        guard t != themeCache else { return }
        themeCache = t
        NSApp.appearance = t == 1 ? NSAppearance(named: .aqua) : t == 2 ? NSAppearance(named: .darkAqua) : nil
        MainActor.assumeIsolated { menuBar?.applyTheme() }
    }
    var glass: NSGlassEffectView!
    var hosting: NSView!
    var size: WidgetSize { WidgetSize.current }
    let store = MainActor.assumeIsolated { UsageStore() }

    // MARK: Window layout
    //
    // The window is always large-widget sized, and the glass sits inside it at the corner chosen in
    // Resize direction. Changing size then only animates the glass: resizing a transparent window
    // makes macOS redraw it from scratch, which flashes. Clicks on the empty, fully transparent
    // part pass through on their own (macOS hit-tests transparent pixels; tested on macOS 26),
    // so no mouse monitoring is needed.

    static let windowSize = Grid.outer(.large)
    private var anchorCache: (Bool, Bool)?

    /// Which corner stays put: (right edge, bottom edge).
    var anchors: (right: Bool, bottom: Bool) {
        (UserDefaults.standard.bool(forKey: "shrinkRight"), UserDefaults.standard.bool(forKey: "shrinkDown"))
    }

    /// Screen rect of the widget's grid cells (the glass plus its 8pt inset).
    var widgetFrame: NSRect {
        glass.frame.insetBy(dx: -Grid.inset, dy: -Grid.inset)
            .offsetBy(dx: window.frame.minX, dy: window.frame.minY)
    }

    var widgetScreen: NSScreen {
        let c = NSPoint(x: widgetFrame.midX, y: widgetFrame.midY)
        return NSScreen.screens.first { $0.frame.contains(c) } ?? window.screen ?? NSScreen.main ?? NSScreen.screens[0]
    }

    func windowFrame(for w: NSRect) -> NSRect {
        let S = Self.windowSize, a = anchors
        return NSRect(x: a.right ? w.maxX - S.width : w.minX, y: a.bottom ? w.minY : w.maxY - S.height,
                      width: S.width, height: S.height)
    }

    func glassFrame(for w: NSRect, in win: NSRect) -> NSRect {
        NSRect(x: w.minX - win.minX, y: w.minY - win.minY, width: w.width, height: w.height)
            .insetBy(dx: Grid.inset, dy: Grid.inset)
    }

    // MARK: Settings at large size

    /// Where the widget was (cells rect) and its size before settings grew it to large.
    private var expandedFrom: (frame: NSRect, size: WidgetSize)?

    /// Native desktop widgets sit one level above `desktopIconWindow + 1` (ours); while settings
    /// overlap them, go above them, still below every app window.
    static let settingsLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 3)

    /// A panel is opening: grow to large from the Resize direction corner (shifted just enough to
    /// stay on screen; already large stays put), or, when it closes, go back to exactly where it
    /// was, or apply a size picked meanwhile. Never re-snaps or saves size or position while open.
    func setExpanded(_ on: Bool) {
        let state = MainActor.assumeIsolated { WidgetState.shared }
        if on {
            guard expandedFrom == nil else { return }
            let w0 = widgetFrame
            expandedFrom = (w0, size)
            let outer = Grid.outer(.large), a = anchors
            var target = NSRect(x: a.right ? w0.maxX - outer.width : w0.minX,
                                y: a.bottom ? w0.minY : w0.maxY - outer.height,
                                width: outer.width, height: outer.height)
            let v = widgetScreen.visibleFrame
            target.origin.x = min(max(target.minX, v.minX), v.maxX - target.width)
            target.origin.y = min(max(target.minY, v.minY), v.maxY - target.height)
            window.draggable = false
            if window.level.rawValue < Self.settingsLevel.rawValue { window.level = Self.settingsLevel }
            window.orderFrontRegardless()
            WidgetSize.noteChange(from: size.rawValue, to: WidgetSize.large.rawValue)
            MainActor.assumeIsolated { withAnimation(WidgetSize.changeAnimation) { state.expanded = true } }
            moveGlass(to: target)
        } else {
            guard let from = expandedFrom else { return }
            expandedFrom = nil
            // Same size as before: the same spot. A size picked while settings were open: grow or
            // shrink from that spot, then snap like any size change.
            var target = from.frame
            if size != from.size {
                let outer = Grid.outer(size), a = anchors
                target = Grid.snappedFrame(near: NSRect(x: a.right ? from.frame.maxX - outer.width : from.frame.minX,
                                                        y: a.bottom ? from.frame.minY : from.frame.maxY - outer.height,
                                                        width: outer.width, height: outer.height),
                                           size: size, on: widgetScreen)
                UserDefaults.standard.set(NSStringFromPoint(target.origin), forKey: "widgetOrigin")
            }
            WidgetSize.noteChange(from: WidgetSize.large.rawValue, to: size.rawValue)
            MainActor.assumeIsolated { withAnimation(WidgetSize.changeAnimation) { state.expanded = false } }
            window.draggable = true
            moveGlass(to: target) { [weak self] in
                guard let self else { return }
                self.applyLevel(UserDefaults.standard.bool(forKey: "floatOnTop"))
                Grid.refreshPlacement { self.resnapIfCovered() }
            }
        }
    }

    var isExpanded: Bool { expandedFrom != nil }

    /// Animate the glass to `target` (screen rect of its cells). If that needs a different window
    /// position, the window jumps first (same size, no redraw) with the glass kept visually still.
    func moveGlass(to target: NSRect, completion: (() -> Void)? = nil) {
        let w0 = widgetFrame
        let win = windowFrame(for: target)
        if win != window.frame {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            window.setFrame(win, display: true)
            glass.frame = glassFrame(for: w0, in: win)
            CATransaction.commit()
        }
        if Motion.reduced {
            glass.frame = glassFrame(for: target, in: win)
            completion?()
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = WidgetSize.duration
            let c = WidgetSize.curve
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: Float(c.0), Float(c.1), Float(c.2), Float(c.3))
            ctx.allowsImplicitAnimation = true
            glass.animator().frame = glassFrame(for: target, in: win)
        }, completionHandler: { completion?() })
    }

    /// Put the widget at `w` (screen rect of its cells) immediately.
    func place(_ w: NSRect) {
        let win = windowFrame(for: w)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        window.setFrame(win, display: false)
        glass.frame = glassFrame(for: w, in: win)
        CATransaction.commit()
    }

    /// "Desktop widget" setting (the X can hide it). If both the widget and the menu bar
    /// gauge end up off, the app would be invisible, so bring the widget back.
    func syncWidgetVisibility() {
        guard let window else { return }
        let d = UserDefaults.standard
        var show = d.object(forKey: "showWidget") as? Bool ?? true
        if !show && !(d.object(forKey: "menuBar") as? Bool ?? true) {
            d.set(true, forKey: "showWidget")
            show = true
        }
        if show && !window.isVisible { window.orderFrontRegardless() }
        if !show && window.isVisible {
            if let from = expandedFrom {   // hidden with settings open: close them and put it back
                expandedFrom = nil
                MainActor.assumeIsolated { WidgetState.shared.expanded = false; WidgetCommand.closePanels.send() }
                place(from.frame)
                window.draggable = true
                applyLevel(d.bool(forKey: "floatOnTop"))
            }
            window.orderOut(nil)
        }
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        AppMenu.installMainMenu()
        Housekeeping.migrate(now: Date())
        Housekeeping.runIfDue(now: Date())
        UNUserNotificationCenter.current().delegate = self
        applyTheme()
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.applyTheme()
            self.updateFocus()
            self.syncWidgetVisibility()
            // Resize direction changed: keep the widget where it is, re-anchor the window around it.
            let a = self.anchors
            if let c = self.anchorCache, c != (a.right, a.bottom), self.window != nil { self.place(self.widgetFrame) }
            self.anchorCache = (a.right, a.bottom)
        }
        let root = WidgetView(store: store,
                              onLevelChange: { [weak self] onTop in self?.applyLevel(onTop) },
                              onSizeChange: { [weak self] _ in self?.applySize() },
                              onExpand: { [weak self] on in self?.setExpanded(on) })
        let inner = Grid.inner(size)
        let host = ClickThroughHostingView(rootView: root)
        host.sizingOptions = []   // the glass sets the size (and animates it), not SwiftUI
        hosting = host
        hosting.frame = NSRect(origin: .zero, size: inner)
        hosting.autoresizingMask = [.width, .height]

        // Liquid Glass panel, inset inside its grid cells exactly like native widgets.
        glass = NSGlassEffectView(frame: NSRect(origin: NSPoint(x: Grid.inset, y: Grid.inset), size: inner))
        glass.style = .regular
        glass.cornerRadius = Grid.cornerRadius
        glass.tintColor = Self.glassTint
        glass.contentView = hosting

        let container = NSView(frame: NSRect(origin: .zero, size: Self.windowSize))
        container.addSubview(glass)

        window = WidgetWindow(contentRect: container.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = container
        window.contextMenu = { [weak self] in AppMenu.contextMenu(store: self?.store, forMenuBar: false) }
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.acceptsMouseMovedEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        applyLevel(UserDefaults.standard.bool(forKey: "floatOnTop"))
        anchorCache = (anchors.right, anchors.bottom)

        let screen = NSScreen.main ?? NSScreen.screens[0]
        var start = Grid.topRight(size: size, in: screen.visibleFrame)
        if let saved = UserDefaults.standard.string(forKey: "widgetOrigin") {
            start.origin = NSPointFromString(saved)
        }
        place(start)
        snap(animated: false)
        Grid.refreshPlacement { [weak self] in self?.resnapIfCovered() }
        window.onDragEnd = { [weak self] in
            self?.snap(animated: true)
            Grid.refreshPlacement { self?.resnapIfCovered() }
        }
        syncWidgetVisibility()


        // Fade/unfade as the user moves between apps and the desktop, like native widgets.
        updateFocus()
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            self?.updateFocus()
            // Native widgets can only be moved from the desktop, so look again on the way there.
            if self?.finderFrontmost == true { Grid.refreshPlacement { self?.resnapIfCovered() } }
        }

        // A native widget can be dropped onto ours: while on the desktop, look every 10 seconds
        // (a cheap window-list read). Elsewhere nothing can move them, so don't look.
        Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            guard let self, self.finderFrontmost, self.window.isVisible else { return }
            Grid.refreshPlacement { self.resnapIfCovered() }
        }

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.snap(animated: false)
            Grid.refreshPlacement { self?.snap(animated: false) }
        }

        MainActor.assumeIsolated {
            let pop = WidgetView(store: store, forceLarge: true,
                                 onLevelChange: { [weak self] onTop in self?.applyLevel(onTop) },
                                 onSizeChange: { _ in })
                // The popover's own glass lets whatever's behind it wash out the text,
                // so give the content a near-solid backing (adapts to light/dark).
                .background(Rectangle().fill(.background.opacity(0.9)).ignoresSafeArea())
            let host = NSHostingController(rootView: pop)
            host.preferredContentSize = NSSize(width: Grid.widgetSize(2), height: Grid.widgetSize(2))
            menuBar = MenuBarController(store: store, content: host)
            let firstRun = Welcome.needed()
            store.keychainAllowed = !firstRun
            store.start()
            if firstRun { Welcome.show(store: store) }
            UpdateChecker.shared.start()
        }
    }

    var finderFrontmost: Bool { NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder" }

    /// Native widgets don't know about this one, so one can be dropped on top of it.
    /// If that happens, move to the nearest free slot.
    func resnapIfCovered() {
        guard !isExpanded else { return }   // overlapping is fine while settings are open
        let w = widgetFrame
        let target = Grid.snappedFrame(near: w, size: size, on: widgetScreen)
        if abs(target.minX - w.minX) > 1 || abs(target.minY - w.minY) > 1 {
            snap(animated: true)
        }
    }

    func snap(animated: Bool) {
        guard !isExpanded else { return }
        let target = Grid.snappedFrame(near: widgetFrame, size: size, on: widgetScreen)
        let win = windowFrame(for: target)
        if animated {   // the window only moves here (never resizes), so this stays smooth
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                window.animator().setFrame(win, display: true)
            })
        } else {
            place(target)
        }
        UserDefaults.standard.set(NSStringFromPoint(target.origin), forKey: "widgetOrigin")
    }

    /// Switch size (small 1×1, medium 2×1, large 2×2), growing/shrinking from the corner chosen
    /// in Resize direction; moves to the nearest free slot if that spot is taken.
    func applySize() {
        // A size picked while settings are open applies when they close (see setExpanded).
        guard !isExpanded else { return }
        let w0 = widgetFrame
        let outer = Grid.outer(size), a = anchors
        let anchored = NSRect(x: a.right ? w0.maxX - outer.width : w0.minX,
                              y: a.bottom ? w0.minY : w0.maxY - outer.height,
                              width: outer.width, height: outer.height)
        let target = Grid.snappedFrame(near: anchored, size: size, on: widgetScreen)
        UserDefaults.standard.set(NSStringFromPoint(target.origin), forKey: "widgetOrigin")
        moveGlass(to: target) {
            Grid.refreshPlacement { [weak self] in self?.resnapIfCovered() }   // the new size may overlap a native widget
        }
    }

    func applyLevel(_ onTop: Bool) {
        if isExpanded && !onTop {   // settings open over native widgets: stay above them until closed
            window.level = Self.settingsLevel
            window.orderFrontRegardless()
            return
        }
        window.level = onTop
            ? .floating
            : NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        window.orderFrontRegardless()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // no Dock icon
app.run()
