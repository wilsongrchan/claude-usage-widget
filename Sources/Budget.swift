// Weekly budget splits, hourly usage logging, the 24-hour rose diagram, and the gear glyph.

import AppKit
import SwiftUI

// MARK: - Ring slices

func uniformSlices(_ n: Int) -> [Double] { (0...n).map { Double($0) / Double(n) } }

// MARK: - Weekly budget

/// How the weekly limit is split across the 7 days of the current window.
/// Mode 0 = 7 even days, 1 = weekdays only (Mon–Fri), 2 = custom % per weekday.
struct WeekBudget {
    static let dayNames = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
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
    static func weekdayIndex(_ d: Date) -> Int {
        (Calendar.current.component(.weekday, from: d) + 5) % 7
    }

    init?(resetsAt: Date?, now: Date) {
        guard let resetsAt else { return nil }
        let mode = UserDefaults.standard.integer(forKey: "weeklySplit")
        let custom = WeekBudget.custom
        let start = resetsAt.addingTimeInterval(-7 * 86400)

        var raw = (0..<7).map { k -> Double in
            let idx = WeekBudget.weekdayIndex(start.addingTimeInterval(Double(k) * 86400 + 60))
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

        let t = now.timeIntervalSince(start)
        let k = min(max(Int(t / 86400), 0), 6)
        let frac = min(max((t - Double(k) * 86400) / 86400, 0), 1)
        current = k
        expected = boundaries[k] + frac * shares[k]
    }
}

// MARK: - Hourly usage log (today's session usage, bucketed by hour)

enum HourlyLog {
    static func key(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return "hourly-\(c.year!)-\(c.month!)-\(c.day!)"
    }

    static func today(_ now: Date) -> [Double] {
        let a = (UserDefaults.standard.array(forKey: key(now)) as? [Double]) ?? []
        return a.count == 24 ? a : Array(repeating: 0, count: 24)
    }

    /// Attributes the rise in session usage since the last reading to the current hour.
    static func record(_ u: Usage, now: Date) {
        let d = UserDefaults.standard
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
        var arr = today(now)
        arr[Calendar.current.component(.hour, from: now)] += delta
        d.set(arr, forKey: key(now))
    }
}

// MARK: - Rose diagram

struct Wedge: Shape {
    let start: Double, end: Double     // fractions of the circle, 0 = top, clockwise
    let inner: Double, outer: Double   // fractions of the radius

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let R = min(rect.width, rect.height) / 2
        let pad = 0.004
        let a0 = (start + pad) * 2 * .pi - .pi / 2, a1 = (end - pad) * 2 * .pi - .pi / 2
        func pt(_ r: Double, _ a: Double) -> CGPoint { CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a)) }
        var p = Path()
        let steps = 6
        p.move(to: pt(R * inner, a0))
        for i in 0...steps { p.addLine(to: pt(R * outer, a0 + (a1 - a0) * Double(i) / Double(steps))) }
        for i in (0...steps).reversed() { p.addLine(to: pt(R * inner, a0 + (a1 - a0) * Double(i) / Double(steps))) }
        p.closeSubpath()
        return p
    }
}

/// Ray tapering toward the centre with a rounded tip — gives the chart a spark/starburst look.
struct RayShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let tipR = w / 2            // rounded outer tip
        let baseR = w * 0.24        // rounded inner end, narrower → petal tapers toward the centre
        let tip = CGPoint(x: rect.midX, y: rect.minY + tipR)
        let base = CGPoint(x: rect.midX, y: rect.maxY - baseR)
        var p = Path()
        p.move(to: CGPoint(x: rect.midX - baseR, y: base.y))
        p.addLine(to: CGPoint(x: rect.midX - tipR, y: tip.y))
        p.addArc(center: tip, radius: tipR, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
        p.addLine(to: CGPoint(x: rect.midX + baseR, y: base.y))
        p.addArc(center: base, radius: baseR, startAngle: .degrees(0), endAngle: .degrees(180), clockwise: false)
        p.closeSubpath()
        return p
    }
}

/// 24 rays radiating from a hollow centre (midnight at top, clockwise); ray length ∝ √usage,
/// so a busy day reads like an uneven orange spark.
struct RoseDiagram: View {
    let values: [Double]
    let currentHour: Int
    var diameter: CGFloat = 150
    var centerValue: String? = nil
    var centerLabel: String? = nil

    var body: some View {
        let maxV = max(values.max() ?? 0, 0.0001)
        let R = diameter / 2
        let inner = R * 0.42
        let rayW = max(diameter * 0.055, 4)
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                .frame(width: inner * 2 - 3, height: inner * 2 - 3)
            // Ghost petals: every hour at full length in faint grey, so the spark shape is always visible.
            ForEach(0..<24, id: \.self) { h in
                RayShape()
                    .fill(Color.primary.opacity(h == currentHour ? 0.16 : 0.07))
                    .frame(width: rayW, height: R - inner)
                    .offset(y: -(inner + (R - inner) / 2))
                    .rotationEffect(.degrees(Double(h) / 24 * 360))   // centred on the hour, so labels line up
            }
            ForEach(0..<24, id: \.self) { h in
                let v = values[h]
                let len = (R - inner) * (0.18 + 0.82 * sqrt(v / maxV))
                RayShape()
                    .fill(h == currentHour ? Palette.ember : Palette.claude)
                    .opacity(v > 0 ? 1 : 0)
                    .frame(width: rayW, height: len)
                    .offset(y: -(inner + len / 2))
                    .rotationEffect(.degrees(Double(h) / 24 * 360))   // centred on the hour, so labels line up
                    .help("\(h):00 – \(String(format: "%.1f", v))% of a session")
            }
            ForEach([0, 6, 12, 18], id: \.self) { h in
                let a = Double(h) / 24 * 2 * .pi
                Text(h == 0 ? "12a" : h == 12 ? "12p" : h < 12 ? "\(h)a" : "\(h - 12)p")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .offset(x: sin(a) * (R + 10), y: -cos(a) * (R + 10))
            }
            if let centerValue {
                VStack(spacing: -2) {
                    Text(centerValue)
                        .font(.system(size: diameter * 0.12, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .minimumScaleFactor(0.6)
                    if let centerLabel {
                        Text(centerLabel)
                            .font(.system(size: max(diameter * 0.055, 7), weight: .semibold))
                            .textCase(.uppercase)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: inner * 2 - 4)
            }
        }
        .frame(width: diameter, height: diameter)
        .padding(20)   // room for the 12a / 6a / 12p / 6p labels
        .contentShape(Rectangle())
    }
}

// MARK: - Gear glyph (8 squared teeth, solid body, large hole)

struct GearShape: Shape {
    /// Absolute width of the solid ring between hole and tooth roots (nil = proportional).
    var ringWidth: CGFloat? = nil

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let R = min(rect.width, rect.height) / 2
        let r = R * 0.76
        let hole = ringWidth.map { r - $0 } ?? R * 0.40
        let n = 8, step = 2 * Double.pi / Double(n)
        let topHalf = step * 0.25, baseHalf = step * 0.33
        func pt(_ rad: Double, _ a: Double) -> CGPoint { CGPoint(x: c.x + rad * cos(a), y: c.y + rad * sin(a)) }
        var p = Path()
        for k in 0..<n {
            let a = Double(k) * step - .pi / 2
            if k == 0 { p.move(to: pt(r, a - baseHalf)) } else { p.addLine(to: pt(r, a - baseHalf)) }
            p.addLine(to: pt(R, a - topHalf))
            p.addLine(to: pt(R, a + topHalf))
            p.addLine(to: pt(r, a + baseHalf))
            // Root arc to the next tooth.
            let from = a + baseHalf, to = a + step - baseHalf
            for i in 1...4 { p.addLine(to: pt(r, from + (to - from) * Double(i) / 4)) }
        }
        p.closeSubpath()
        p.addEllipse(in: CGRect(x: c.x - hole, y: c.y - hole, width: hole * 2, height: hole * 2))
        return p
    }
}
