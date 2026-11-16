// The 24-hour rose diagram and the gear glyph. (Budget maths and the hourly log: Core/Budget.swift.)

import AppKit
import SwiftUI

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
                    .help("\(uses24Hour ? "\(h):00" : "\(h % 12 == 0 ? 12 : h % 12) \(h < 12 ? "AM" : "PM")") – \(String(format: "%.1f", v))% of a session")
            }
            ForEach([0, 6, 12, 18], id: \.self) { h in
                let a = Double(h) / 24 * 2 * .pi
                // Follows the Mac's 12/24-hour setting: 12a 6a 12p 6p, or 0 6 12 18.
                Text(uses24Hour ? "\(h)" : h == 0 ? "12a" : h == 12 ? "12p" : h < 12 ? "\(h)a" : "\(h - 12)p")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
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
                            .font(.system(size: max(diameter * 0.055, 10), weight: .semibold))
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
