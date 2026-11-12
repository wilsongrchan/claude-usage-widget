// Claude Usage Widget — a Liquid Glass desktop widget showing live Claude plan limits.
// Reads the Claude Code login from the macOS Keychain (never stored or logged)
// and polls https://api.anthropic.com/api/oauth/usage.

import AppKit
import SwiftUI
import UserNotifications

// MARK: - API model

struct UsageWindow: Decodable {
    let utilization: Double?
    let resets_at: String?
}

struct LimitEntry: Decodable {
    struct Scope: Decodable {
        struct Model: Decodable { let display_name: String? }
        let model: Model?
    }
    let kind: String
    let percent: Double?
    let resets_at: String?
    let scope: Scope?
}

struct Breakdown: Decodable {
    struct Row: Decodable { let display_name: String?; let percent: Double? }
    let rows: [Row]?
}

struct Usage: Decodable {
    let five_hour: UsageWindow?
    let seven_day: UsageWindow?
    let limits: [LimitEntry]?
    let seven_day_breakdown: Breakdown?
}

enum WidgetError: LocalizedError {
    case msg(String)
    case rateLimited(retryAfter: TimeInterval?)
    var errorDescription: String? {
        switch self {
        case .msg(let m): return m
        case .rateLimited: return "Rate limited"
        }
    }
}

func parseDate(_ s: String?) -> Date? {
    guard let s else { return nil }
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: s) { return d }
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: s)
}

// MARK: - Data store

@MainActor
final class UsageStore: ObservableObject {
    @Published var usage: Usage?
    @Published var error: String?
    @Published var lastUpdated: Date?
    @Published var now = Date()
    @Published var loading = false
    /// True when the desktop isn't focused: the widget fades like native widgets.
    @Published var dimmed = false
    /// Soft status (rate limited / offline) shown in grey while the last good data stays on screen.
    @Published var pausedReason: String?
    @Published var nextRetry: Date?

    private var pollInterval: TimeInterval = 60
    private var pollTimer: Timer?
    private var clockTimer: Timer?

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
        if let t = lastUpdated, Date().timeIntervalSince(t) < 50 {
            // fresh enough; the regular poll will pick it up
        } else {
            Task { await refresh() }
        }
        schedulePoll()
        clockTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in
            Task { @MainActor in self.now = Date(); ResetReminder.check(); LimitAlerts.checkSessionReset(now: Date()) }
        }
    }

    private func schedulePoll() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { _ in
            Task { @MainActor in await self.refresh() }
        }
    }

    func refresh() async {
        loading = true
        defer { loading = false; now = Date() }
        do {
            let (result, raw) = try await Task.detached { try await UsageStore.fetch() }.value
            usage = result
            error = nil
            pausedReason = nil
            nextRetry = nil
            lastUpdated = Date()
            UserDefaults.standard.set(raw, forKey: "lastUsageData")
            UserDefaults.standard.set(lastUpdated, forKey: "lastUsageDate")
            Forecast.record(result, now: Date())
            HourlyLog.record(result, now: Date())
            LimitAlerts.check(result, now: Date())
            if pollInterval != 60 { pollInterval = 60; schedulePoll() }
        } catch WidgetError.rateLimited(let retryAfter) {
            // Back off: honour the server's Retry-After if given, else double the wait (max 10 min).
            error = nil
            pausedReason = "Updates paused"
            pollInterval = min(max(retryAfter ?? pollInterval * 2, 60), 600)
            nextRetry = Date().addingTimeInterval(pollInterval)
            schedulePoll()
        } catch is URLError {
            error = nil
            pausedReason = "Offline"
            nextRetry = Date().addingTimeInterval(pollInterval)
        } catch {
            pausedReason = nil
            self.error = error.localizedDescription
        }
    }

    nonisolated static func readToken() throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw WidgetError.msg("Claude Code login not found in Keychain. Run `claude` and log in.")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String else {
            throw WidgetError.msg("Couldn't read Claude Code credentials.")
        }
        return token
    }

    nonisolated static func fetch() async throws -> (Usage, Data) {
        let token = try readToken()
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("claude-usage-widget/1.0", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        switch code {
        case 200: return (try JSONDecoder().decode(Usage.self, from: data), data)
        case 401, 403: throw WidgetError.msg("Login expired. Use Claude Code once to refresh it.")
        case 429:
            let retry = (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
            throw WidgetError.rateLimited(retryAfter: retry)
        default: throw WidgetError.msg("Usage API returned HTTP \(code)")
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
    static let rust   = Color(hex: 0x9B1C1C)   // dark red — nearing the limit
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

    var body: some View {
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
                        // Track — the current slice is highlighted.
                        Circle()
                            .trim(from: a, to: b)
                            .stroke(Palette.claude.opacity(segmented && k == today ? 0.32 : 0.16),
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
            .animation(.easeOut(duration: 0.6), value: percent)

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

struct BarRow: View {
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
                    Capsule().fill(Palette.claude.opacity(0.16))
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
    @Environment(\.widgetDimmed) private var dimmed

    var body: some View {
        if let elapsed {
            let diff = percent - elapsed * 100
            let d = Int(abs(diff).rounded())
            let (text, icon, color): (String, String, Color) =
                diff >= 3  ? (short ? "Ahead +\(d)%" : "Ahead of pace +\(d)%", "arrow.up.right.circle.fill", diff >= 15 ? Palette.rust : Palette.ember)
              : diff <= -3 ? (short ? "\(d)% spare" : "\(d)% to spare", "checkmark.circle.fill", Palette.claude)
              :              ("On pace", "equal.circle.fill", Palette.claude)
            Label(text, systemImage: icon)
                .font(.system(size: short ? 10 : 11, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(dimmed ? Color.white.opacity(0.95) : color)
                .lineLimit(1)
                .help("Ahead of pace means you're using this limit faster than time is passing, and may hit it before it resets.")
        }
    }
}

// MARK: - Saved limit resets (tracked manually — the usage API doesn't expose them)

enum ResetReminder {
    /// Default expiry: the Nov 2026 free full reset, which expires Dec 10, 2026 at 2pm PT.
    static let defaultExpiry: Double = {
        var c = DateComponents()
        c.year = 2026; c.month = 12; c.day = 10; c.hour = 14
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")
        return Calendar(identifier: .gregorian).date(from: c)!.timeIntervalSince1970
    }()
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
    static var expiry: Double {
        let v = UserDefaults.standard.double(forKey: "resetExpiry")
        return v > 0 ? v : defaultExpiry
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
        let n = count, exp = expiry
        let remaining = exp - Date().timeIntervalSince1970
        guard n > 0, remaining > 0 else { return }
        let thresholds = ResetReminder.leads   // ascending, in seconds
        guard let hit = thresholds.first(where: { remaining <= Double($0) }) else { return }
        let key = "notified-\(Int(exp))-\(hit)"
        guard !d.bool(forKey: key) else { return }
        for t in thresholds where t >= hit { d.set(true, forKey: "notified-\(Int(exp))-\(t)") }

        Notifier.post(id: key, title: "Claude limit reset expiring",
                      body: "You have \(n) saved reset\(n == 1 ? "" : "s") expiring in \(remainingText(remaining)). Click to use it in Settings → Usage.")
    }
}

/// Chip showing saved resets and their expiry; opens the editor when clicked.
struct ResetChip: View {
    @AppStorage("resetCount") var count = 0
    @AppStorage("resetExpiry") var expiry: Double = ResetReminder.defaultExpiry
    let now: Date
    var compact = false
    var onTap: () -> Void = {}

    var body: some View {
        let remaining = expiry - now.timeIntervalSince1970
        let active = count > 0 && remaining > 0
        let color = active ? ResetReminder.color(remaining) : Color.secondary

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

/// Settings gear: 8 squared teeth, solid body, large hole.
struct GearGlyph: View {
    var body: some View {
        GearShape(ringWidth: GlyphMetrics.stroke)   // same ring weight as the pace & segment glyphs
            .fill(style: FillStyle(eoFill: true))
            .frame(width: GlyphMetrics.size + 1, height: GlyphMetrics.size + 1)
    }
}

struct IconButton<Glyph: View>: View {
    var active = false
    let help: String
    let action: () -> Void
    @ViewBuilder let glyph: () -> Glyph

    var body: some View {
        Button(action: action) {
            glyph()
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 22, height: 22)
                .foregroundStyle(active ? Palette.claude : Color.primary.opacity(0.62))   // explicit grey: shapes and SF Symbols match
                .background(Circle().fill(active ? Palette.claude.opacity(0.18) : Color.primary.opacity(0.07)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help.isEmpty ? "" : help)
    }
}

struct ControlBar: View {
    @ObservedObject var store: UsageStore
    var showSizeToggle = true
    var showRefresh = false
    var onSettings: () -> Void = {}
    @AppStorage("menuBar") var menuBar = true
    @AppStorage("floatOnTop") var floatOnTop = false
    @AppStorage("showPaceMarker") var showPaceMarker = true
    @AppStorage("segmentedRings") var segmentedRings = true
    @AppStorage("compact") var compact = false
    var onLevelChange: (Bool) -> Void
    var onSizeChange: (Bool) -> Void

    // In-widget tooltip (macOS only shows .help tooltips for the active app, which a desktop widget rarely is).
    @State private var tip: String?
    @State private var tipTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 3) {
            if showRefresh {
                IconButton(help: "Refresh now", action: { Task { await store.refresh() } }) {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(store.loading)
                .opacity(store.loading ? 0.5 : 1)
                .onHover { hover($0, store.loading ? "Refreshing…" : "Refresh") }
            }
            IconButton(active: showPaceMarker, help: "",
                       action: { withAnimation { showPaceMarker.toggle() } }) {
                PaceGlyph()
            }
            .onHover { hover($0, "Pace marker") }
            IconButton(active: segmentedRings, help: "",
                       action: { withAnimation { segmentedRings.toggle() } }) {
                SegmentGlyph()
            }
            .onHover { hover($0, "Segmented rings") }
            if showSizeToggle {
                IconButton(help: "", action: { compact.toggle(); onSizeChange(compact) }) {
                    Image(systemName: compact ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left")
                }
                .onHover { hover($0, compact ? "Large size" : "Small size") }
            }
            IconButton(help: "", action: onSettings) {
                GearGlyph()
            }
            .onHover { hover($0, "Settings") }
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
                    .frame(width: (compact && showSizeToggle) ? 136 : 210, alignment: .trailing)
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

// MARK: - Widget

struct WidgetView: View {
    @ObservedObject var store: UsageStore
    @AppStorage("showPaceMarker") var showPaceMarker = true
    @AppStorage("segmentedRings") var segmentedRings = true
    @AppStorage("compact") var compactSetting = false
    @AppStorage("resetCount") var resetCount = 0
    @State private var hovering = false
    @State private var stack: [Panel] = []
    @AppStorage("showScoped") var showScoped = true
    /// Used by the menu bar popover, which always shows the large layout.
    var forceLarge = false
    var compact: Bool { !forceLarge && compactSetting }
    var dimmedNow: Bool { store.dimmed && !forceLarge && stack.isEmpty }
    var onLevelChange: (Bool) -> Void
    var onSizeChange: (Bool) -> Void

    var controls: ControlBar {
        ControlBar(store: store, showSizeToggle: !forceLarge, showRefresh: true, onSettings: { open(.settings) },
                   onLevelChange: onLevelChange, onSizeChange: onSizeChange)
    }

    var body: some View {
        Group { if let p = stack.last { panelView(p) } else { VStack(alignment: .leading, spacing: 0) {
            if !compact { header.zIndex(1) }
            if let u = store.usage {
                if compact { compactContent(u) } else { content(u) }
            } else if let err = store.error ?? store.notice {
                Spacer()
                errorLabel(err)
                Spacer()
            } else {
                Spacer()
                ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                Spacer()
            }
        } } }
        .padding(compact ? 10 : 16)
        .frame(width: Grid.widgetSize(compact ? 1 : 2), height: Grid.widgetSize(compact ? 1 : 2))
        .overlay(alignment: .top) {
            // Small widget: controls float in on hover.
            if compact && hovering && stack.isEmpty {
                controls
                    .padding(4)
                    .background(Capsule().fill(.regularMaterial))
                    .padding(.top, 6)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
        // Like native desktop widgets: when you're working in an app, fade to a translucent
        // monochrome look; full colour returns when you click the desktop.
        .environment(\.widgetDimmed, dimmedNow)
        .compositingGroup()
        .saturation(dimmedNow ? 0 : 1)
        .brightness(dimmedNow ? 0.32 : 0)
        .opacity(dimmedNow ? 0.92 : 1)
        .animation(.easeInOut(duration: 0.35), value: dimmedNow)
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

        // Fixed gap (never reacts to status text). When the Fable bar is hidden, push the rings
        // down by half that bar's space so the empty space above and below evens out.
        let hasScoped = showScoped && (u.limits ?? []).contains { $0.kind == "weekly_scoped" }
        Color.clear.frame(height: hasScoped ? 10 : 22)
        HStack(alignment: .top) {
            VStack(spacing: 5) {
                RingGauge(percent: session, elapsed: sElapsed, slices: segmentedRings ? uniformSlices(5) : [0, 1],
                          showMarker: showPaceMarker, label: "Session")
                    .help("Each slice is one hour of the 5-hour session. The white tick marks now.")
                Text(resetText(sReset, now: store.now)).caption()
                PaceNote(percent: session, elapsed: sElapsed)
                if aheadOfPace(session, sElapsed) {
                    ForecastNote(hit: Forecast.hitTime(util: session, resetsAt: sReset, duration: 5 * 3600,
                                                       now: store.now, useRecent: true), now: store.now)
                }
            }
            .frame(maxWidth: .infinity)
            VStack(spacing: 5) {
                RingGauge(percent: weekly, elapsed: wElapsed,
                          slices: segmentedRings ? (budget?.boundaries ?? uniformSlices(7)) : [0, 1],
                          current: budget?.current, showMarker: showPaceMarker, label: "Weekly")
                    .help("Each slice is one day's budget. The white tick marks where you should be by now.")
                Text(resetText(wReset, now: store.now)).caption()
                PaceNote(percent: weekly, elapsed: wElapsed)
                if aheadOfPace(weekly, wElapsed) {
                    ForecastNote(hit: Forecast.hitTime(util: weekly, resetsAt: wReset, duration: 7 * 86400,
                                                       now: store.now, useRecent: false), now: store.now)
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
                      showMarker: showPaceMarker, showCenter: false, diameter: outer, lineWidth: weeklyLine)
            RingGauge(percent: session, elapsed: sElapsed, slices: segmentedRings ? uniformSlices(5) : [0, 1],
                      showMarker: showPaceMarker, showCenter: false,
                      diameter: outer - 2 * (weeklyLine + 5), lineWidth: sessionLine)
            VStack(spacing: -1) {
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text("\(Int(session.rounded()))")
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                    Text("%")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                Text("WK \(Int(weekly.rounded()))%")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .tracking(0.5)
                    .foregroundStyle(usageColor(weekly))
            }
            .monospacedDigit()
        }
        .padding(.top, 6)   // sit the rings a touch lower in the small widget
        .frame(maxWidth: .infinity)
        .help("Outer ring: weekly limit (7 days). Inner ring: 5-hour session. White ticks mark now.")
        .overlay(alignment: .topTrailing) {
            if let age = ageText(store.lastUpdated, now: store.now),
               store.notice != nil || store.now.timeIntervalSince(store.lastUpdated ?? store.now) > 150 {
                Text(age)
                    .font(.system(size: 9, weight: .semibold))
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
            if aheadOfPace(session, sElapsed),
               let hit = Forecast.hitTime(util: session, resetsAt: sReset, duration: 5 * 3600,
                                          now: store.now, useRecent: true) {
                ForecastNote(hit: hit, now: store.now, short: true)
            } else {
                PaceNote(percent: session, elapsed: sElapsed, short: true)
            }
            Spacer(minLength: 0)
            HStack(spacing: 2) {
                SessionResetGlyph().scaleEffect(0.62).frame(width: 10, height: 10)
                Text(compactReset(sReset))
            }
            .font(.system(size: 10, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(dimmedNow ? AnyShapeStyle(Color.white.opacity(0.85)) : AnyShapeStyle(.secondary))
            .help(resetText(sReset, now: store.now).capitalized(with: nil) + " (5-hour session)")
        }
        .font(.system(size: 10))
    }

    func open(_ p: Panel) {
        if p == .settings { UserDefaults.standard.set(0, forKey: "settingsTab") }   // always start on Appearance
        NSApp.activate()   // lets the date field take keyboard input
        withAnimation(.easeOut(duration: 0.2)) { stack.append(p) }
    }

    var nav: Nav {
        Nav(push: { p in withAnimation(.easeOut(duration: 0.2)) { stack.append(p) } },
            pop: { withAnimation(.easeOut(duration: 0.2)) { _ = stack.popLast() } })
    }

    @ViewBuilder
    func panelView(_ p: Panel) -> some View {
        switch p {
        case .settings:
            SettingsPanel(store: store, nav: nav, compact: compact, allowSize: !forceLarge,
                          onLevelChange: onLevelChange, onSizeChange: onSizeChange)
        case .appearance:
            AppearancePanel(nav: nav, allowSize: !forceLarge,
                            onLevelChange: onLevelChange, onSizeChange: onSizeChange, small: compact)
        case .alerts:
            AlertsPanel(nav: nav, compact: compact)
        case .data:
            DataPanel(store: store, nav: nav, compact: compact)
        case .resets:
            ResetPanel(now: store.now, compact: compact, nav: nav)
        case .about:
            AboutPanel(nav: nav, compact: compact)
        }
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
                    if store.loading { ProgressView().controlSize(.mini) }
                }
                HStack(spacing: 5) {
                    // Always present (blank if unknown) so the header height never changes.
                    if let age = ageText(store.lastUpdated, now: store.now) ?? Optional(" ") {
                        Text(age == " " ? " " : "Updated \(age)")
                            .font(.system(size: 10, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
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
            controls.opacity(hovering ? 1 : 0.55)
        }
    }
}

/// Small inline ↻ next to "Updated …".
struct RefreshButton: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        Button { Task { await store.refresh() } } label: {
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
// Native desktop widgets sit on a 180pt grid that starts 16pt in from the top-left of the
// screen's visible area; each widget is inset 8pt inside its cells (small = 164pt,
// large = 344pt). This widget is "large" (2×2 cells) and snaps to that grid, avoiding
// cells already taken by native widgets (read from Notification Center's placement data).

enum Grid {
    static let pitch: CGFloat = 180
    static let margin: CGFloat = 16
    static let inset: CGFloat = 8
    static func outerSize(_ span: Int) -> CGFloat { pitch * CGFloat(span) }        // 180 / 360
    static func widgetSize(_ span: Int) -> CGFloat { outerSize(span) - inset * 2 }  // 164 / 344

    struct Cell: Hashable { let col: Int; let row: Int }

    static func dims(_ v: NSRect) -> (cols: Int, rows: Int) {
        (Int((v.width - margin * 2 + 1) / pitch), Int((v.height - margin * 2 + 1) / pitch))
    }

    /// Window frame (AppKit, bottom-left origin) for a cell whose top-left is (col,row).
    static func frame(for c: Cell, span: Int, in v: NSRect) -> NSRect {
        NSRect(x: v.minX + margin + CGFloat(c.col) * pitch,
               y: v.maxY - margin - CGFloat(c.row) * pitch - outerSize(span),
               width: outerSize(span), height: outerSize(span))
    }

    /// Cells occupied by native widgets on a display with this visible size.
    static func occupied(visibleSize: CGSize) -> Set<Cell> {
        guard let widgets = UserDefaults(suiteName: "com.apple.notificationcenterui")?.dictionary(forKey: "widgets"),
              let data = widgets["DesktopWidgetPlacementStorage"] as? Data,
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let displays = root["NumberedDisplays"] as? [[String: Any]] else { return [] }
        var cells = Set<Cell>()
        for display in displays {
            for res in (display["Resolutions"] as? [[String: Any]]) ?? [] {
                guard let size = res["Size"] as? [Double], size.count == 2,
                      abs(size[0] - visibleSize.width) < 1, abs(size[1] - visibleSize.height) < 1 else { continue }
                for group in (res["Groups"] as? [[String: Any]]) ?? [] {
                    let origin = (group["Origin"] as? [Double]) ?? [16, 16]
                    let dc = Int(((origin[0] - margin) / pitch).rounded())
                    let dr = Int(((origin[1] - margin) / pitch).rounded())
                    for item in (group["Items"] as? [[String: Any]]) ?? [] {
                        guard let col = item["Column"] as? Int, let row = item["Row"] as? Int else { continue }
                        let sizeKey = (item["Size"] as? [String: Any])?.keys.first ?? "Small"
                        let (w, h): (Int, Int) = switch sizeKey {
                            case "Medium": (2, 1)
                            case "Large": (2, 2)
                            case "ExtraLarge": (4, 2)
                            default: (1, 1)
                        }
                        for x in 0..<w { for y in 0..<h { cells.insert(Cell(col: col + dc + x, row: row + dr + y)) } }
                    }
                }
            }
        }
        return cells
    }

    /// Nearest free span×span slot to `point` (window origin) on the given screen.
    static func snappedFrame(near frame: NSRect, span: Int, on screen: NSScreen) -> NSRect {
        let v = screen.visibleFrame
        let (cols, rows) = dims(v)
        let taken = occupied(visibleSize: v.size)
        var best: (NSRect, CGFloat, Bool)?
        for col in 0...max(cols - span, 0) {
            for row in 0...max(rows - span, 0) {
                let f = Grid.frame(for: Cell(col: col, row: row), span: span, in: v)
                let free = !(0..<span).contains { x in (0..<span).contains { y in taken.contains(Cell(col: col + x, row: row + y)) } }
                let d = hypot(f.minX - frame.minX, f.minY - frame.minY)
                if let b = best {
                    // Prefer free slots; among equals, prefer nearest.
                    if (free && !b.2) || (free == b.2 && d < b.1) { best = (f, d, free) }
                } else {
                    best = (f, d, free)
                }
            }
        }
        return best?.0 ?? frame
    }
}

// MARK: - Window / app

final class WidgetWindow: NSWindow {
    var onDragEnd: (() -> Void)?
    private var dragStart: NSPoint?
    private var originStart: NSPoint = .zero
    private var dragged = false

    override var canBecomeKey: Bool { true }

    // Manual dragging so we know exactly when the drag ends and can snap to the grid.
    override func sendEvent(_ e: NSEvent) {
        switch e.type {
        case .leftMouseDown:
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
        glass.tintColor = dim ? nil : Self.glassTint
        window.appearance = dim ? NSAppearance(named: .darkAqua) : nil   // white text, like native dimmed widgets
    }

    /// Auto / Light / Dark — applied app-wide so the widget and menu bar popover match.
    func applyTheme() {
        let t = UserDefaults.standard.integer(forKey: "theme")
        guard t != themeCache else { return }
        themeCache = t
        NSApp.appearance = t == 1 ? NSAppearance(named: .aqua) : t == 2 ? NSAppearance(named: .darkAqua) : nil
    }
    var glass: NSGlassEffectView!
    var hosting: NSView!
    var span: Int { UserDefaults.standard.bool(forKey: "compact") ? 1 : 2 }
    let store = MainActor.assumeIsolated { UsageStore() }

    func applicationDidFinishLaunching(_ note: Notification) {
        UNUserNotificationCenter.current().delegate = self
        applyTheme()
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.applyTheme()
            self?.updateFocus()
        }
        let root = WidgetView(store: store,
                              onLevelChange: { [weak self] onTop in self?.applyLevel(onTop) },
                              onSizeChange: { [weak self] _ in self?.applySize() })
        let size = Grid.widgetSize(span)
        hosting = ClickThroughHostingView(rootView: root)
        hosting.frame = NSRect(x: 0, y: 0, width: size, height: size)
        hosting.autoresizingMask = [.width, .height]

        // Liquid Glass panel, inset inside its grid cells exactly like native widgets.
        glass = NSGlassEffectView(frame: NSRect(x: Grid.inset, y: Grid.inset, width: size, height: size))
        glass.style = .regular
        glass.cornerRadius = 24
        glass.tintColor = Self.glassTint
        glass.contentView = hosting

        let container = NSView(frame: NSRect(x: 0, y: 0, width: Grid.outerSize(span), height: Grid.outerSize(span)))
        container.addSubview(glass)

        window = WidgetWindow(contentRect: container.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = container
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        applyLevel(UserDefaults.standard.bool(forKey: "floatOnTop"))

        let screen = NSScreen.main ?? NSScreen.screens[0]
        var start = Grid.frame(for: Grid.Cell(col: Grid.dims(screen.visibleFrame).cols - span, row: 0),
                               span: span, in: screen.visibleFrame)
        if let saved = UserDefaults.standard.string(forKey: "widgetOrigin") {
            let p = NSPointFromString(saved)
            start.origin = p
        }
        window.setFrame(start, display: false)
        snap(animated: false)
        window.onDragEnd = { [weak self] in self?.snap(animated: true) }
        window.orderFrontRegardless()

        // Fade/unfade as the user moves between apps and the desktop, like native widgets.
        updateFocus()
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            self?.updateFocus()
        }

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.snap(animated: false)
        }

        MainActor.assumeIsolated {
            let pop = WidgetView(store: store, forceLarge: true,
                                 onLevelChange: { [weak self] onTop in self?.applyLevel(onTop) },
                                 onSizeChange: { _ in })
            let host = NSHostingController(rootView: pop)
            host.preferredContentSize = NSSize(width: Grid.widgetSize(2), height: Grid.widgetSize(2))
            menuBar = MenuBarController(store: store, content: host)
            store.start()
        }
    }

    func snap(animated: Bool) {
        let screen = window.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let target = Grid.snappedFrame(near: window.frame, span: span, on: screen)
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                window.animator().setFrame(target, display: true)
            }
        } else {
            window.setFrame(target, display: true)
        }
        UserDefaults.standard.set(NSStringFromPoint(target.origin), forKey: "widgetOrigin")
    }

    /// Switch between small (1 slot) and large (2×2), keeping the top-left corner, then re-snap.
    func applySize() {
        let outer = Grid.outerSize(span), inner = Grid.widgetSize(span)
        glass.cornerRadius = span == 1 ? 22 : 24
        glass.frame = NSRect(x: Grid.inset, y: Grid.inset, width: inner, height: inner)
        hosting.frame = NSRect(x: 0, y: 0, width: inner, height: inner)
        let f = window.frame
        window.setFrame(NSRect(x: f.minX, y: f.maxY - outer, width: outer, height: outer), display: true)
        snap(animated: true)
    }

    func applyLevel(_ onTop: Bool) {
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
