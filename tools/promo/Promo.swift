import SwiftUI
import AVFoundation
import CoreImage
import UniformTypeIdentifiers

// Promo video: the app's real views, driven frame by frame, written to MP4 with AVAssetWriter.

let W: CGFloat = 1920, H: CGFloat = 1080   // drawn at this size
let OW: CGFloat = 1280, OH: CGFloat = 720   // written at this size
let FPS: Int32 = 60
let TOTAL: Double = 20 + 0.6 + 0.5 + 0.6 + 0.7 + 1.0 + 0.25 - 3.65
let iconPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""
let outPath = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "promo.mp4"
let onlyFrames: [Double] = CommandLine.arguments.count > 3 ? CommandLine.arguments[3].split(separator: ",").compactMap { Double($0) } : []

nonisolated(unsafe) var promoHover = false

// MARK: - Timing helpers

func clamp01(_ x: Double) -> Double { min(max(x, 0), 1) }
func seg(_ t: Double, _ a: Double, _ b: Double) -> Double { clamp01((t - a) / (b - a)) }
func easeOut(_ x: Double) -> Double { 1 - pow(1 - x, 3) }
func easeInOut(_ x: Double) -> Double { x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2 }
func lerp(_ a: Double, _ b: Double, _ x: Double) -> Double { a + (b - a) * x }
func lerp(_ a: CGFloat, _ b: CGFloat, _ x: Double) -> CGFloat { a + (b - a) * CGFloat(x) }
/// Visible between a and b, fading in/out over `f` seconds.
func window(_ t: Double, _ a: Double, _ b: Double, fade f: Double = 0.45) -> Double {
    min(easeInOut(seg(t, a, a + f)), 1 - easeInOut(seg(t, b - f, b)))
}

func easeOutBack(_ x: Double) -> Double { let c1 = 1.9, c3 = c1 + 1; return 1 + c3 * pow(x - 1, 3) + c1 * pow(x - 1, 2) }
/// A click's squish: dips, overshoots, settles.
func squish(_ x: Double) -> CGFloat { x < 0 ? 1 : CGFloat(1 - 0.07 * exp(-6 * x) * sin(20 * x)) }

/// Scene changes, on the beat (120 BPM): quick zoom in, hold, quick zoom out (no spin).
let cuts: [(t: Double, dir: Double)] = []   // no zoom punches: scenes fade or slide
func camera(_ t: Double) -> (s: CGFloat, r: Double, blur: CGFloat) {
    for c in cuts {
        let x = t - c.t
        if x > -0.2 && x < 0 { let q = (x + 0.2) / 0.2, e = q * q * q; return (1 + 0.22 * CGFloat(e), c.dir * 2 * e, CGFloat(7 * e)) }
        if x >= 0 && x < 0.4 { let q = x / 0.4; return (1.22 - 0.04 * CGFloat(q), c.dir * lerp(2, 5, easeOut(q)), CGFloat(max(0, 7 * (1 - q * 3)))) }
        if x >= 0.4 && x < 0.6 { let u = (x - 0.4) / 0.2, q = easeOut(u); return (lerp(1.18, 1, q), c.dir * lerp(5, 0, q), CGFloat(5 * sin(.pi * u))) }
    }
    return (1, 0, 0)
}

/// Glambot move: fast in (to 80%), then a slow creep (to 100% at b), and the next scene takes over
/// while it's still close in: it never zooms back out. `v` is video time.
func glamZ(_ v: Double, _ a: Double, _ b: Double, fast: Double = 0.35) -> Double {
    if v < a { return 0 }
    if v < a + fast { return 0.8 * easeOut((v - a) / fast) }
    return 0.8 + 0.2 * min(1, (v - a - fast) / (b - a - fast))
}

/// A camera move on the footage (headlines stay put): zoom about `focus`, drifting it by `drift`.
struct Glam: ViewModifier {
    let z: Double, maxScale: CGFloat, focus: CGPoint, drift: CGSize
    func body(content: Content) -> some View {
        content
            .scaleEffect(1 + (maxScale - 1) * CGFloat(z), anchor: UnitPoint(x: focus.x / W, y: focus.y / H))
            .offset(x: drift.width * CGFloat(z), y: drift.height * CGFloat(z))
    }
}

/// Little lines bursting out from a click.
struct ClickBurst: View {
    let age: Double   // seconds since the click
    var color: Color = Palette.claude
    var body: some View {
        let q = clamp01(age / 0.38)
        ZStack {
            ForEach(0..<8, id: \.self) { i in
                Capsule().fill(color)
                    .frame(width: 4, height: lerp(16, 6, q))
                    .offset(y: -lerp(16, 46, easeOut(q)))
                    .rotationEffect(.degrees(Double(i) * 45 + 22.5))
            }
        }
        .opacity(age < 0 || age > 0.38 ? 0 : 1 - q * q)
    }
}

let ink = Color(red: 0.11, green: 0.11, blue: 0.12)
let ink2 = Color(red: 0.43, green: 0.43, blue: 0.45)

// MARK: - Data

let cal = Calendar.current
let base: Date = cal.date(from: DateComponents(year: 2026, month: 11, day: 17, hour: 13, minute: 0))!
let iso = ISO8601DateFormatter()

func usage(session: Double, sReset: Date, weekly: Double, wReset: Date, model: Double) -> Usage {
    let json = """
    {"five_hour":{"utilization":\(session),"resets_at":"\(iso.string(from: sReset))"},
     "seven_day":{"utilization":\(weekly),"resets_at":"\(iso.string(from: wReset))"},
     "limits":[{"kind":"weekly_scoped","percent":\(model),"resets_at":"\(iso.string(from: wReset))",
                "scope":{"model":{"display_name":"Fable"}}}]}
    """
    return try! JSONDecoder().decode(Usage.self, from: Data(json.utf8))
}

let sReset = base.addingTimeInterval(3 * 3600)              // 16:00, two hours into the session
let wReset = base.addingTimeInterval(2 * 86400 + 5 * 3600)  // Thu 18:00

// MARK: - Pieces

struct Headline: View {
    let text: String
    var sub: String? = nil
    let p: Double       // 0…1 visibility (fades it out at the end)
    var age: Double = 10   // seconds since it started: words pop in one by one
    var big = false
    var light = false   // white text, for the wallpaper
    var body: some View {
        let lines = text.components(separatedBy: "\n").map { $0.split(separator: " ").map(String.init) }
        let starts = lines.indices.map { li in lines[..<li].reduce(0) { $0 + $1.count } }
        let count = lines.reduce(0) { $0 + $1.count }
        let subQ = clamp01((age - Double(count) * 0.07 - 0.05) / 0.3)
        VStack(spacing: 14) {
            VStack(spacing: 0) {
                ForEach(lines.indices, id: \.self) { li in
                    HStack(spacing: big ? 24 : 16) {
                        ForEach(lines[li].indices, id: \.self) { wi in
                            let q = clamp01((age - Double(starts[li] + wi) * 0.07) / 0.3)
                            Text(lines[li][wi])
                                .font(.system(size: big ? 96 : 64, weight: .semibold))
                                .tracking(big ? -2 : -1.2)
                                .foregroundStyle(light ? Color.white : ink)
                                .scaleEffect(lerp(CGFloat(0.4), CGFloat(1), easeOutBack(q)))
                                .offset(y: CGFloat(1 - easeOutBack(q)) * 30)
                                .opacity(min(1, q * 3))
                        }
                    }
                }
            }
            if let sub {
                Text(sub)
                    .font(.system(size: big ? 36 : 30, weight: .regular))
                    .foregroundStyle(light ? Color.white.opacity(0.9) : ink2)
                    .multilineTextAlignment(.center)
                    .opacity(subQ)
                    .offset(y: CGFloat(1 - easeOut(subQ)) * 14)
            }
        }
        .shadow(color: .black.opacity(light ? 0.35 : 0), radius: 12, y: 2)
        .opacity(age < 0.6 ? 1 : p)
        .scaleEffect(age < 0.6 ? 1 : lerp(CGFloat(0.96), CGFloat(1), p))
    }
}

/// Soft warm/cool gradient with drifting light, like a quiet desktop.
struct Backdrop: View {
    let t: Double
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.97, green: 0.94, blue: 0.91), Color(red: 0.91, green: 0.91, blue: 0.97)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle().fill(Color(red: 1.0, green: 0.78, blue: 0.66).opacity(0.55))
                .frame(width: 900, height: 900).blur(radius: 160)
                .offset(x: -520 + CGFloat(sin(t * 0.25)) * 60, y: -260 + CGFloat(cos(t * 0.2)) * 40)
            Circle().fill(Color(red: 0.72, green: 0.76, blue: 1.0).opacity(0.5))
                .frame(width: 1000, height: 1000).blur(radius: 170)
                .offset(x: 560 + CGFloat(cos(t * 0.22)) * 60, y: 300 + CGFloat(sin(t * 0.18)) * 40)
        }
        .frame(width: W, height: H)
    }
}

/// Glass-like widget card around real widget content.
struct Card<C: View>: View {
    let size: CGSize
    var dim: Double = 0
    @ViewBuilder let content: C
    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: Grid.cornerRadius, style: .continuous)
                .fill(Color.white.opacity(0.72 * (1 - dim)))
            RoundedRectangle(cornerRadius: Grid.cornerRadius, style: .continuous)
                .fill(Color.black.opacity(0.16 * dim))
            content
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: Grid.cornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Grid.cornerRadius, style: .continuous)
            .strokeBorder(Color.white.opacity(lerp(0.9, 0.45, dim)), lineWidth: 1))
        .shadow(color: .black.opacity(0.10), radius: 30, y: 14)
    }
}

struct Cursor: View {
    var pressed = false
    var body: some View {
        Path { p in
            p.move(to: .init(x: 0, y: 0)); p.addLine(to: .init(x: 0, y: 22)); p.addLine(to: .init(x: 5.5, y: 17))
            p.addLine(to: .init(x: 9.5, y: 26)); p.addLine(to: .init(x: 13, y: 24.5)); p.addLine(to: .init(x: 9, y: 16))
            p.addLine(to: .init(x: 16, y: 16)); p.closeSubpath()
        }
        .fill(Color.black)
        .overlay(Path { p in
            p.move(to: .init(x: 0, y: 0)); p.addLine(to: .init(x: 0, y: 22)); p.addLine(to: .init(x: 5.5, y: 17))
            p.addLine(to: .init(x: 9.5, y: 26)); p.addLine(to: .init(x: 13, y: 24.5)); p.addLine(to: .init(x: 9, y: 16))
            p.addLine(to: .init(x: 16, y: 16)); p.closeSubpath()
        }.stroke(Color.white, lineWidth: 1.5))
        .frame(width: 18, height: 28, alignment: .topLeading)
        .scaleEffect(pressed ? 1.35 : 1.5, anchor: .topLeading)
        .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
    }
}

let appIcon: NSImage? = NSImage(contentsOfFile: iconPath)
let wallpaper: NSImage? = CommandLine.arguments.count > 4 ? NSImage(contentsOfFile: CommandLine.arguments[4]) : nil
let wallpaper2: NSImage? = CommandLine.arguments.count > 5 ? NSImage(contentsOfFile: CommandLine.arguments[5]) : nil   // sizes scene (Ventura)

struct Banner: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let appIcon { Image(nsImage: appIcon).resizable().frame(width: 40, height: 40) }
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Claude Usage").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text("now").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Text("Session limit: 80% used").font(.system(size: 13, weight: .semibold))
                Text("You've used 80% of your 5-hour session limit. It resets in 1h 12m.")
                    .font(.system(size: 13)).foregroundStyle(ink.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(width: 360)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.white.opacity(0.82)))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.white, lineWidth: 1))
        .shadow(color: .black.opacity(0.14), radius: 24, y: 10)
        .environment(\.colorScheme, .light)
    }
}

struct MenuBarStrip: View {
    let pct: Double
    let now: Date
    var body: some View {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB"); f.dateFormat = "EEE d MMM  HH:mm"
        return HStack(spacing: 0) {
            HStack(spacing: 20) {
                Image(systemName: "applelogo").font(.system(size: 15, weight: .medium))
                Text("Finder").font(.system(size: 13, weight: .bold))
                ForEach(["File", "Edit", "View", "Go", "Window", "Help"], id: \.self) { Text($0).font(.system(size: 13)) }
            }
            Spacer()
            HStack(spacing: 16) {
                HStack(spacing: 3) {
                    Image(nsImage: MenuBarController.gaugeImage(pct))
                    Text("\(Int(pct.rounded()))%").font(.system(size: 13, weight: .medium)).monospacedDigit()
                }
                Image(systemName: "battery.75percent").font(.system(size: 15))
                Image(systemName: "wifi").font(.system(size: 13, weight: .medium))
                Image(systemName: "switch.2").font(.system(size: 13, weight: .medium))
                Text(f.string(from: now)).font(.system(size: 13)).monospacedDigit()
            }
        }
        .foregroundStyle(Color.white)
        .shadow(color: .black.opacity(0.25), radius: 2)
        .padding(.horizontal, 16)
        .frame(width: W / 1.5, height: 25)
        .background(Color.black.opacity(0.10))
    }
}

let dockApps: [NSImage] = [
    "/System/Library/CoreServices/Finder.app", "/Applications/Safari.app", "/System/Applications/Messages.app",
    "/System/Applications/Mail.app", "/System/Applications/Maps.app", "/System/Applications/Photos.app",
    "/System/Applications/Calendar.app", "/System/Applications/Notes.app", "/System/Applications/Reminders.app",
    "/System/Applications/Music.app", "/System/Applications/App Store.app", "/System/Applications/System Settings.app",
    "/System/Applications/Utilities/Terminal.app", "/Applications/Claude Usage.app",
].map { sharp(NSWorkspace.shared.icon(forFile: $0)) }

/// NSWorkspace icons default to a small size; ask for the 512 px version so they stay crisp.
func sharp(_ i: NSImage) -> NSImage { i.size = NSSize(width: 512, height: 512); return i }

struct DesktopIcons: View {
    static let items: [(String, NSImage)] = [
        ("Projects", sharp(NSWorkspace.shared.icon(for: .folder))), ("Screenshots", sharp(NSWorkspace.shared.icon(for: .folder))),
        ("Design", sharp(NSWorkspace.shared.icon(for: .folder))), ("Notes.pdf", sharp(NSWorkspace.shared.icon(for: .pdf))),
    ]
    var body: some View {
        VStack(spacing: 18) {
            ForEach(Self.items.indices, id: \.self) { i in
                VStack(spacing: 4) {
                    Image(nsImage: Self.items[i].1).resizable().interpolation(.high).frame(width: 64, height: 64)
                    Text(Self.items[i].0).font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
                }
            }
        }
    }
}

struct Dock: View {
    var body: some View {
        HStack(spacing: 4) {
            ForEach(dockApps.indices, id: \.self) { i in
                if i == dockApps.count - 2 { Rectangle().fill(Color.white.opacity(0.35)).frame(width: 1, height: 40).padding(.horizontal, 5) }
                Image(nsImage: dockApps[i]).resizable().interpolation(.high).frame(width: 52, height: 52)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color.white.opacity(0.28)))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.white.opacity(0.45), lineWidth: 1))
        .shadow(color: .black.opacity(0.15), radius: 16, y: 6)
    }
}

struct Triangle: Shape {
    func path(in r: CGRect) -> Path {
        Path { p in p.move(to: .init(x: r.midX, y: r.minY)); p.addLine(to: .init(x: r.maxX, y: r.maxY)); p.addLine(to: .init(x: r.minX, y: r.maxY)); p.closeSubpath() }
    }
}

// Generic stand-ins for other desktop widgets (no real app's design or branding).
struct MockWeather: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("London").font(.system(size: 13, weight: .semibold))
                    Text("12°").font(.system(size: 40, weight: .light))
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Image(systemName: "cloud.sun.fill").symbolRenderingMode(.multicolor).font(.system(size: 20))
                    Text("Partly cloudy").font(.system(size: 11, weight: .medium))
                    Text("H:14° L:8°").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            HStack {
                ForEach(Array(["15", "16", "17", "18", "19"].enumerated()), id: \.offset) { i, h in
                    VStack(spacing: 3) {
                        Text(h).font(.system(size: 10)).foregroundStyle(.secondary)
                        Image(systemName: i < 2 ? "cloud.sun.fill" : "cloud.fill").symbolRenderingMode(.multicolor).font(.system(size: 12))
                        Text("\(12 - i / 2)°").font(.system(size: 11, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .foregroundStyle(.primary)
        .padding(14)
    }
}

struct MockClock: View {
    var body: some View {
        VStack(spacing: 2) {
            Text("NEW YORK").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            Text("09:30").font(.system(size: 38, weight: .semibold, design: .rounded)).monospacedDigit()
            Text("−5h").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
        }
        .foregroundStyle(.primary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct MockCalendar: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("TUESDAY").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.red)
            Text("17").font(.system(size: 36, weight: .light))
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 1).fill(Color.blue).frame(width: 3, height: 26)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Design review").font(.system(size: 11, weight: .semibold)).lineLimit(1)
                    Text("15:00–16:00").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
        }
        .foregroundStyle(.primary)
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct MockReminders: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Image(systemName: "list.bullet.circle.fill").foregroundStyle(Color.orange).font(.system(size: 18))
                Spacer()
                Text("3").font(.system(size: 20, weight: .semibold))
            }
            ForEach(["Ship v0.2.1", "Post on Reddit", "Groceries"], id: \.self) { r in
                HStack(spacing: 6) {
                    Circle().stroke(Color.secondary.opacity(0.6), lineWidth: 1.2).frame(width: 11, height: 11)
                    Text(r).font(.system(size: 11)).lineLimit(1)
                }
            }
        }
        .foregroundStyle(.primary)
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Frame

@MainActor
final class Promo {
    let store = UsageStore()
    let dimStore = UsageStore()
    var v: Double = 0   // video time (scene time pauses during holds)
    var ts: Double = 0  // scene time
    /// Rings close-up while the tick moves, and the menu bar popover.
    var glamTitle: Glam { Glam(z: glamZ(v, 0.55, 1.2), maxScale: 1.15, focus: CGPoint(x: W / 2, y: H / 2), drift: .zero) }
    var glamDesktop: Glam { Glam(z: 0, maxScale: 1, focus: .zero, drift: .zero) }   // no push-in on the monochrome desktop
    var glamRings: Glam { Glam(z: glamZ(v, 3.1, 5.9), maxScale: 1.65, focus: Self.ringCentre, drift: Self.ringDrift) }
    var glamPopover: Glam { Glam(z: glamZ(ts, 16.45, 17.95), maxScale: 1.45, focus: CGPoint(x: 1530, y: 308), drift: .zero) }

    /// The app's own dimmed look (WidgetView.body applies these on top of the layout).
    func dimmedWidget(_ s: WidgetSize) -> some View {
        WidgetView(store: dimStore, onLevelChange: { _ in }, onSizeChange: { _ in }, onExpand: { _ in })
            .layout(s)
            .environment(\.colorScheme, .dark)
            .compositingGroup().saturation(0).brightness(0.32).opacity(0.8)
    }

    func widget(_ s: WidgetSize, forceLarge: Bool = false) -> some View {
        WidgetView(store: store, forceLarge: forceLarge, onLevelChange: { _ in }, onSizeChange: { _ in }, onExpand: { _ in })
            .layout(s)
    }

    /// Sets the store for time t (seconds into the video).
    func setData(_ t: Double) {
        let fill = easeOut(seg(t, 1.4, 2.6))
        // Two hours pass in under three seconds: the tick moves, usage climbs.
        let lapse = easeInOut(seg(t, 3.0, 5.6))
        var now = base.addingTimeInterval(lapse * 5400)
        var s: Double = lerp(46.0, 72.0, lapse), w: Double = lerp(41.0, 47.0, lapse), m = 39.0
        if t < 3.0 { s *= fill; w *= fill; m *= fill }
        if t >= 13.4 { s = 80; w = 52; now = base.addingTimeInterval(6480) }   // alerts scene
        let saved: WidgetSize = t < Self.c3 ? .large : t < Self.c4 ? .medium : .small
        UserDefaults.standard.set(saved.rawValue, forKey: WidgetSize.key)
        promoHover = t > 10.55 && t < Self.c4 + 0.2
        store.now = now
        store.lastUpdated = now.addingTimeInterval(-20)
        store.usage = usage(session: s, sReset: sReset, weekly: w, wReset: wReset, model: m)
        dimStore.usage = store.usage; dimStore.now = store.now; dimStore.lastUpdated = store.lastUpdated; dimStore.dimmed = true
    }

    @ViewBuilder
    func frame(_ t: Double) -> some View {
        let k: CGFloat = 1.7   // widget scale on screen
        ZStack {
            // 9.15–9.65: the desktop slides in from the right, pushing the sizes scene off to the left.
            let slide = easeInOut(seg(t, 9.15, 9.65))
            let sliding = false
            let outX = sliding ? -W * CGFloat(slide) : 0, inX = sliding ? W * CGFloat(1 - slide) : 0
            Backdrop(t: t).offset(x: outX)
            let wp = t < 13.5 ? 0 : t < 16 ? 1 : window(t, 9.3, 18.1, fade: 0.4)
            if wp > 0 { wallpaperView.modifier(glamPopover).opacity(wp) }

            // 1. Title
            let a1 = window(t, 0, 1.2, fade: 0.3)
            if a1 > 0 {
                VStack(spacing: 26) {
                    SegmentGlyph().foregroundStyle(Palette.claude).scaleEffect(9).frame(width: 110, height: 110)
                        .rotationEffect(.degrees(lerp(-160, 0, easeOutBack(seg(t, 0.0, 0.5)))))
                        .scaleEffect(lerp(CGFloat(0.2), CGFloat(1), easeOutBack(seg(t, 0.0, 0.45))))
                        .opacity(easeOut(seg(t, 0.0, 0.15)))
                    Headline(text: "Claude Usage", sub: "Your Claude limits. Right on your desktop.",
                             p: 1, age: t - 0.12, big: true)
                }
                .modifier(glamTitle)
                .opacity(t < 0.6 ? 1 : a1)
            }

            // 2. Large widget: fills up, then time passes.
            let a2 = window(t, 1.0, 6.0, fade: 0.35)
            if a2 > 0 { Group {
                let appear = seg(t, 1.15, 1.6)
                // Hands over to the sizes scene at 5.9 in the same spot: no fade, no cut.
                if t < 5.9 {
                    Card(size: Grid.inner(.large)) { widget(.large) }
                        .scaleEffect(k * lerp(CGFloat(0.85), CGFloat(1), easeOut(appear)))
                        .opacity(easeOut(min(1, appear * 2)) * (1 - easeInOut(seg(t, 5.3, 5.55))))
                        .position(x: W / 2, y: 625)
                        .modifier(glamRings)
                }
                Headline(text: "Session and weekly.\nAt a glance.", p: window(t, 1.3, 3.4, fade: 0.35), age: t - 1.3)
                    .position(x: W / 2, y: 190)
                Headline(text: "Every slice is an hour.", sub: "The white tick shows where you should be by now.",
                         p: window(t, 3.3, 5.95, fade: 0.3), age: t - 3.3)
                    .position(x: W / 2, y: 190)
            }
            .opacity(t < 3 ? a2 : 1) }

            // 3. Sizes
            let a3 = window(t, 5.8, 9.5, fade: 0.35)
            if t >= 5.9 && t < 9.65 { sizes(t, k: k).offset(x: outX) }
            if t >= 5.3 && t < 10.1 { ringTransition(t) }

            // 4. On a desktop, among other widgets
            let aD = t < 9.15 ? 0 : t < 12 ? 1 : window(t, 9.3, 13.8, fade: 0.35)
            if aD > 0 {
                // Its own wallpaper and chrome, so the push-in carries them and the next scene
                // fades in underneath, unzoomed.
                ZStack {
                    wallpaperView
                    desktop(t, headlines: false)
                    chrome
                }
                .modifier(glamDesktop)
                .opacity(aD).offset(x: inX)
                desktop(t, headlines: true).opacity(aD).offset(x: inX)
            }

            if wp > 0 { chrome.modifier(glamPopover).opacity(wp) }

            // 5. Alerts, then the menu bar
            let a4 = window(t, 13.5, 18.1, fade: 0.35)
            if a4 > 0 { Group {
                let bn = easeOut(seg(t, 14.1, 14.55)) - easeInOut(seg(t, 15.6, 16.0))
                Banner().scaleEffect(1.5).position(x: W - 300 + (1 - bn) * 620, y: 150).modifier(glamPopover)
                Card(size: Grid.inner(.medium)) { widget(.medium) }
                    .scaleEffect(k * lerp(CGFloat(0.85), CGFloat(1), easeOut(seg(t, 13.8, 14.25))))
                    .position(x: 1290, y: 600)
                    .opacity(1 - easeInOut(seg(t, 15.6, 16.0)))
                Headline(text: "A heads-up before\nyou hit the limit.", sub: "Alerts at the levels you choose.",
                         p: window(t, 13.65, 15.9, fade: 0.35), age: t - 13.65, light: true)
                    .position(x: 520, y: 560)
                Headline(text: "Always one click away.", sub: "Your session in the menu bar.\nClick it for the full view.",
                         p: window(t, 15.8, 18.1, fade: 0.35), age: t - 15.8, light: true)
                    .position(x: 600, y: 560)
                // Popover under the menu bar item.
                let popRaw = seg(t, 16.05, 16.4), pop = easeOut(min(1, popRaw * 2))
                if pop > 0 {
                    VStack(spacing: 0) {
                        Triangle().fill(Color.white.opacity(0.9)).frame(width: 30, height: 14)
                        Card(size: Grid.inner(.large)) { widget(.large, forceLarge: true) }
                    }
                    .scaleEffect(1.5 * lerp(CGFloat(0.8), CGFloat(1), easeOut(popRaw)), anchor: .top)
                    .opacity(pop)
                    .position(x: Self.menuItemX, y: 40 + (Grid.inner(.large).height + 14) * 1.5 / 2)
                    .modifier(glamPopover)
                }
                let cur = window(t, 15.3, 18.0, fade: 0.25)
                if cur > 0 {
                    let x = lerp(Self.menuItemX + 260, Self.menuItemX - 4, easeInOut(seg(t, 15.4, 16.0)))
                    let y = lerp(CGFloat(520), CGFloat(22), easeInOut(seg(t, 15.4, 16.0)))
                    let pressed = t > 15.95 && t < 16.12
                    ClickBurst(age: t - 16.02).position(x: Self.menuItemX, y: 20).modifier(glamPopover)
                    Cursor(pressed: pressed).frame(width: 0, height: 0, alignment: .topLeading)
                        .position(x: x, y: y).modifier(glamPopover).opacity(cur)
                }
            }
            .opacity(a4) }

            // 5. End card
            let a5 = easeOut(seg(t, 17.95, 18.5))
            if a5 > 0 {
                VStack(spacing: 22) {
                    SegmentGlyph().foregroundStyle(Palette.claude).scaleEffect(6).frame(width: 78, height: 78)
                        .rotationEffect(.degrees(lerp(160, 0, easeOutBack(seg(t, 18.0, 18.5)))))
                        .scaleEffect(lerp(CGFloat(0.2), CGFloat(1), easeOutBack(seg(t, 18.0, 18.45))))
                    Headline(text: "Claude Usage", p: 1, age: t - 18.1)
                    Text("Free and open source. For macOS Tahoe.").font(.system(size: 30)).foregroundStyle(ink2)
                    Text("github.com/wilsongrchan/claude-usage-widget")
                        .font(.system(size: 28, weight: .medium)).foregroundStyle(Palette.claudeText)
                        .padding(.top, 12)
                        .opacity(easeOut(seg(t, 18.25, 18.7)))
                }
                .opacity(a5)
                .offset(y: CGFloat(1 - a5) * 20)
                Text("Unofficial. Not affiliated with Anthropic.")
                    .font(.system(size: 18)).foregroundStyle(ink2.opacity(0.8))
                    .opacity(easeOut(seg(t, 18.45, 18.9)))
                    .position(x: W / 2, y: 1025)
            }
        }
        .frame(width: W, height: H)
        .environment(\.colorScheme, .light)
    }

    @ViewBuilder var wallpaperView: some View {
        if let wallpaper { Image(nsImage: wallpaper).resizable().scaledToFill().frame(width: W, height: H).clipped() }
    }

    /// Menu bar, Dock and desktop files.
    var chrome: some View {
        ZStack {
            MenuBarStrip(pct: store.usage?.five_hour?.utilization ?? 0, now: store.now)
                .scaleEffect(1.5).position(x: W / 2, y: 18.75)
            Dock().scaleEffect(1.3).position(x: W / 2, y: H - 52)
            DesktopIcons().scaleEffect(1.3).position(x: W - 90, y: 290)
        }
        .frame(width: W, height: H)
    }

    static let ringCentre = CGPoint(x: 826, y: 576)   // the session ring, measured in the large card
    static let ringDrift = CGSize(width: 137, height: 165)

    /// The session ring lifts out of its widget, fills and thickens into a disc, grows to cover the
    /// screen in orange, then a circle opens onto the next scene.
    func ringTransition(_ t: Double) -> some View {
        let z = CGFloat(glamZ(v, 3.1, 5.9))
        let S = 1 + 0.65 * z
        let c = CGPoint(x: Self.ringCentre.x + Self.ringDrift.width * z, y: Self.ringCentre.y + Self.ringDrift.height * z)
        let pct = (store.usage?.five_hour?.utilization ?? 0) / 100
        let fillQ = easeInOut(seg(t, 5.5, 5.75))
        let g = seg(t, 5.7, 5.95), grow = lerp(CGFloat(1), CGFloat(9), g * g)
        let D = 136 * 1.7 * S * grow
        let lw = lerp(13 * 1.7 * S * grow, D / 2, fillQ)
        let gap = 0.006 * (1 - fillQ)
        let fill = lerp(pct, 1, fillQ)
        let color = usageColor(pct * 100)
        let iris = easeInOut(seg(t, 9.6, 10.1))   // scene time jumps 5.95 → 9.6 (see holds)
        return ZStack {
            if t >= 5.3 && t < 5.95 {
                ZStack {
                    ForEach(0..<5, id: \.self) { k in
                        let a = Double(k) / 5 + gap, b = Double(k + 1) / 5 - gap
                        if fill > a {
                            Circle().trim(from: a, to: min(b, fill))
                                .stroke(color, style: StrokeStyle(lineWidth: lw, lineCap: .butt))
                        }
                    }
                }
                .rotationEffect(.degrees(-90 + 40 * fillQ))
                .padding(lw / 2)
                .frame(width: D, height: D)
                .overlay(Circle().fill(color).opacity(seg(fillQ, 0.85, 1)))
                .position(c)
            }
            if t >= 9.6 && iris < 1 {
                let r = 1300 * CGFloat(iris), L: CGFloat = 4000   // the hole's radius; a very thick ring around it
                Circle().stroke(color, lineWidth: L).frame(width: 2 * r + L, height: 2 * r + L).position(x: W / 2, y: H / 2)
            }
        }
        .frame(width: W, height: H)
    }

    static let c1 = 7.0, c2 = 8.4   // the two clicks
    static let c3 = 11.0             // desktop scene: large → medium
    static let c4 = 11.85            // then medium → small
    static let menuItemX: CGFloat = 1530   // the menu bar item, at 1.5×

    /// On a desktop among other widgets: the large widget, then a click shrinks it to medium in place.
    func desktop(_ t: Double, headlines: Bool) -> some View {
        let g: CGFloat = 1.4, pitch = Grid.pitch * g, inset = Grid.inset * g
        let x0: CGFloat = 70, y0: CGFloat = 505 - pitch * 3 / 2
        let d = easeInOut(seg(t, 12.35, 12.9))   // working in an app: everything fades to monochrome
        func place<V: View>(_ col: Int, _ row: Int, _ cols: Int, _ rows: Int, order: Int, @ViewBuilder _ v: () -> V) -> some View {
            let w = Grid.widgetSize(cols), h = Grid.widgetSize(rows)
            let q = seg(t, 9.7 + Double(order) * 0.08, 10.05 + Double(order) * 0.08)
            return Card(size: CGSize(width: w, height: h), dim: d) {
                v().compositingGroup().saturation(1 - d).brightness(0.32 * d).opacity(1 - 0.2 * d)
                    .environment(\.colorScheme, d > 0.5 ? .dark : .light)
            }
                .scaleEffect(g * lerp(CGFloat(0.85), CGFloat(1), easeOut(q)))
                .opacity(easeOut(min(1, q * 2.5)))
                .position(x: x0 + CGFloat(col) * pitch + inset + w * g / 2, y: y0 + CGFloat(row) * pitch + inset + h * g / 2)
        }
        let c3 = Self.c3, c4 = Self.c4
        let m3 = easeInOut(seg(t, c3, c3 + 0.5)), m4 = easeInOut(seg(t, c4, c4 + 0.45))
        // Old layout fades out early in each change, the new one in late, overlapping briefly.
        let out3 = 1 - clamp01(m3 * 1.6), in3 = clamp01(m3 * 1.6 - 0.6)   // a short overlap: never an empty card
        let out4 = 1 - clamp01(m4 * 1.6), in4 = clamp01(m4 * 1.6 - 0.6)
        let lg = Grid.inner(.large), md = Grid.inner(.medium), sm = Grid.inner(.small)
        let w = m4 > 0 ? lerp(md.width, sm.width, m4) : lerp(lg.width, md.width, m3)
        let h = m4 > 0 ? lerp(md.height, sm.height, m4) : lerp(lg.height, md.height, m3)
        let left = x0 + inset, top = y0 + pitch + inset   // the Claude widget's slot (col 0, row 1)
        // Size buttons: on large [small, medium], on medium [small, large].
        let medBtn = CGPoint(x: left + 267.5 * g, y: top + 26.5 * g)
        let smBtn = CGPoint(x: left + 241.5 * g, y: top + 26.5 * g)
        let start = CGPoint(x: left + 520, y: top + 560)
        let away = CGPoint(x: left + 520, y: top + 380)
        func mix(_ a: CGPoint, _ b: CGPoint, _ x: Double) -> CGPoint { CGPoint(x: lerp(a.x, b.x, x), y: lerp(a.y, b.y, x)) }
        let cp = t < 11.45 ? mix(start, medBtn, easeInOut(seg(t, 9.9, 10.6)))
               : t < 12.0 ? mix(medBtn, smBtn, easeInOut(seg(t, 11.5, 11.75)))
               : mix(smBtn, away, easeInOut(seg(t, 12.0, 12.5)))
        let pressed = (t > c3 - 0.14 && t < c3 + 0.02) || (t > c4 - 0.14 && t < c4 + 0.02)
        return ZStack {
            if headlines {
            Headline(text: "Right at home.", sub: "Sits on the same grid\nas your other widgets.", p: window(t, 9.75, 11.0, fade: 0.3), age: t - 9.75, light: true)
                .position(x: 1390, y: 500)
            Headline(text: "Three sizes. One click.", sub: "Large, medium or small.", p: window(t, 10.95, 12.4, fade: 0.3), age: t - 10.95, light: true)
                .position(x: 1390, y: 500)
            Headline(text: "Quiet while you work.", sub: "Fades to monochrome,\njust like your other widgets.", p: window(t, 12.35, 13.8, fade: 0.35), age: t - 12.35, light: true)
                .position(x: 1390, y: 500)
            } else {
            place(0, 0, 2, 1, order: 0) { MockWeather() }
            place(2, 0, 1, 1, order: 1) { MockCalendar() }
            place(3, 0, 1, 1, order: 2) { MockClock() }
            place(2, 1, 1, 1, order: 4) { MockReminders() }
            Card(size: CGSize(width: w, height: h), dim: d) {
                ZStack(alignment: .topLeading) {
                    if out3 > 0 { widget(.large).opacity(out3) }
                    if in3 * out4 > 0 { widget(.medium).opacity(in3 * out4) }
                    if in4 > 0 { widget(.small).opacity(in4 * (1 - d)) }
                    if d > 0 { dimmedWidget(.small).opacity(d).environment(\.colorScheme, .dark) }
                }
            }
            .scaleEffect(g, anchor: .topLeading)
            .frame(width: w, height: h, alignment: .topLeading)
            .scaleEffect(squish(t - c3) * squish(t - c4) * lerp(CGFloat(0.85), CGFloat(1), easeOut(seg(t, 9.94, 10.29))))
            .opacity(easeOut(min(1, seg(t, 9.94, 10.29) * 2.5)))
            .position(x: left + w / 2, y: top + h / 2)
            ZStack(alignment: .topLeading) {
                ClickBurst(age: t - c3, color: .white).frame(width: 0, height: 0)
                ClickBurst(age: t - c4, color: .white).frame(width: 0, height: 0)
                Cursor(pressed: pressed)
            }
            .frame(width: 0, height: 0, alignment: .topLeading)
            .position(x: cp.x, y: cp.y)
            .opacity(window(t, 9.8, 12.6, fade: 0.25))
            }
        }
        .frame(width: W, height: H)
    }


    /// Where the cursor is: glides to the size button, clicks, drifts off, comes back, clicks, leaves.
    func cursorPos(_ t: Double, first: CGPoint, second: CGPoint, start: CGPoint) -> CGPoint {
        let rest = CGPoint(x: first.x + 40, y: first.y + 150)
        func mix(_ a: CGPoint, _ b: CGPoint, _ x: Double) -> CGPoint { CGPoint(x: lerp(a.x, b.x, x), y: lerp(a.y, b.y, x)) }
        if t < 7.3 { return mix(start, first, easeInOut(seg(t, 6.0, 6.6))) }
        if t < 7.6 { return mix(first, rest, easeInOut(seg(t, 7.3, 7.6))) }
        if t < 8.6 { return mix(rest, second, easeInOut(seg(t, 7.6, 8.0))) }
        return mix(second, CGPoint(x: rest.x + 160, y: rest.y + 60), easeInOut(seg(t, 8.6, 9.1)))
    }

    /// Large → medium → small with a cursor, then all three side by side.
    @ViewBuilder
    func sizes(_ t: Double, k: CGFloat) -> some View {
        let c1 = Self.c1, c2 = Self.c2
        let m1 = easeInOut(seg(t, c1, c1 + 0.5)), m2 = easeInOut(seg(t, c2, c2 + 0.5))
        let lg = Grid.inner(.large), md = Grid.inner(.medium), sm = Grid.inner(.small)
        let w = m2 > 0 ? lerp(md.width, sm.width, m2) : lerp(lg.width, md.width, m1)
        let h = m2 > 0 ? lerp(md.height, sm.height, m2) : lerp(lg.height, md.height, m1)
        let gallery = 0.0
        let cx = W / 2, top: CGFloat = 625 - lg.height * k / 2, left = cx - lg.width * k / 2
        // Old layout fades out in the first half of the change, the new one in during the second.
        let out1 = 1 - clamp01(m1 * 2), in1 = clamp01(m1 * 2 - 1)
        let out2 = 1 - clamp01(m2 * 2), in2 = clamp01(m2 * 2 - 1)
        ZStack {
            if let wallpaper2 { Image(nsImage: wallpaper2).resizable().scaledToFill().frame(width: W, height: H).clipped() }
            chrome
            // The resizing card, anchored top-left (Resize direction "down-right").
            Card(size: CGSize(width: w, height: h)) {
                ZStack(alignment: .topLeading) {
                    if out1 > 0 { widget(.large).opacity(out1) }
                    if in1 * out2 > 0 { widget(.medium).opacity(in1 * out2) }
                    if in2 > 0 { widget(.small).opacity(in2) }
                }
            }
            .scaleEffect(k, anchor: .topLeading)
            .frame(width: w, height: h, alignment: .topLeading)
            .scaleEffect(squish(t - c1) * squish(t - c2))
            .position(x: left + w / 2, y: top + h / 2)
            .opacity(1 - gallery)

            let cursorOn = window(t, 5.95, 9.25, fade: 0.25)
            if cursorOn > 0 {
                // Large: [small, medium] → click medium. Medium: [small, large] → click small.
                let smallButton = CGPoint(x: left + 241.5 * k, y: top + 26.5 * k)
                let mediumButton = CGPoint(x: smallButton.x + 26 * k, y: smallButton.y)
                let p = cursorPos(t, first: mediumButton, second: smallButton, start: CGPoint(x: cx + 460, y: top + 480))
                let pressed = (t > c1 - 0.14 && t < c1 + 0.02) || (t > c2 - 0.14 && t < c2 + 0.02)
                ZStack(alignment: .topLeading) {
                    ClickBurst(age: t - c1).frame(width: 0, height: 0)
                    ClickBurst(age: t - c2).frame(width: 0, height: 0)
                    Cursor(pressed: pressed)
                }
                .frame(width: 0, height: 0, alignment: .topLeading)
                .position(x: p.x, y: p.y)
                .opacity(cursorOn)
            }

            Headline(text: "Three sizes. One click.", sub: "Large, medium or small.",
                     p: window(t, 6.2, 9.5, fade: 0.3), age: t - 6.2, light: true)
                .position(x: W / 2, y: 175)
        }
        .frame(width: W, height: H)
    }
}

/// Video time → scene time. Holds stretch quiet moments (pops stay snappy): (scene start, scene end, extra seconds).
let holds: [(Double, Double, Double)] = [(5.95, 9.6, -3.65),   // skip: the old sizes scene (now on the desktop)
                                         (10.1, 10.6, 0.6), (11.5, 11.75, 0.5), (13.3, 13.5, 0.6),
                                         (14.6, 15.4, 0.7), (16.85, 17.5, 1.0), (18.9, 20.0, 0.25)]
func sceneTime(_ v: Double) -> Double {
    var shift = 0.0
    for (a, b, e) in holds {
        let ra = a + shift, rb = b + shift + e   // where this hold sits in video time
        if v < ra { return v - shift }
        if v < rb { return a + (v - ra) * (b - a) / (rb - ra) }
        shift += e
    }
    return v - shift
}

// MARK: - Render

@MainActor func run() {
    let d = UserDefaults.standard
    for (k, v) in ["segmentedRings": true, "showPaceMarker": true, "showScoped": true, "showPaceNote": true,
                   "showForecast": true, "menuBar": true] as [String: Any] { d.set(v, forKey: k) }
    d.set(0, forKey: WeeklyRing.key); d.set(0, forKey: ResetTimes.key); d.set(0, forKey: "resetCount")
    d.set(0, forKey: "settingsTab"); d.set(0, forKey: "weeklySplit")
    let promo = Promo()
    let ciContext = CIContext()

    func image(_ v: Double) -> CGImage? {
        let t = sceneTime(v)
        promo.v = v
        promo.ts = t
        promo.setData(t)
        let r = ImageRenderer(content: promo.frame(t))
        r.scale = 1
        r.proposedSize = .init(width: W, height: H)
        guard let cg = r.cgImage else { return nil }
        let cam = camera(t)
        // Zoom about the centre (no spin), with a zoom blur while it moves.
        let tr = CGAffineTransform(translationX: W / 2, y: H / 2)
            .scaledBy(x: cam.s, y: cam.s)
            .translatedBy(x: -W / 2, y: -H / 2)
        var img = CIImage(cgImage: cg).transformed(by: tr)
        if cam.blur > 0.3, let z = CIFilter(name: "CIZoomBlur") {
            z.setValue(img.clampedToExtent(), forKey: kCIInputImageKey)
            z.setValue(CIVector(x: W / 2, y: H / 2), forKey: kCIInputCenterKey)
            z.setValue(cam.blur * 2.2, forKey: kCIInputAmountKey)
            img = z.outputImage ?? img
        }
        img = img.cropped(to: CGRect(x: 0, y: 0, width: W, height: H))
        if let l = CIFilter(name: "CILanczosScaleTransform") {   // down to the output size
            l.setValue(img, forKey: kCIInputImageKey)
            l.setValue(OW / W, forKey: kCIInputScaleKey)
            l.setValue(1.0, forKey: kCIInputAspectRatioKey)
            img = l.outputImage ?? img
        }
        return ciContext.createCGImage(img, from: CGRect(x: 0, y: 0, width: OW, height: OH))
    }

    if !onlyFrames.isEmpty {
        for t in onlyFrames {
            guard let cg = image(t) else { continue }
            let rep = NSBitmapImageRep(cgImage: cg)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: String(format: "f%05.2f.png", t)))
        }
        return
    }

    let url = URL(fileURLWithPath: outPath)
    try? FileManager.default.removeItem(at: url)
    let writer = try! AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(OW), AVVideoHeightKey: Int(OH),
        AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 7_000_000,
                                          AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel],
    ])
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: Int(OW), kCVPixelBufferHeightKey as String: Int(OH)])
    writer.add(input)
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)

    let frames = Int(TOTAL * Double(FPS))
    for i in 0..<frames {
        let t = Double(i) / Double(FPS)
        autoreleasepool {
            guard let cg = image(t) else { print("frame \(i) failed"); return }
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
            guard let buf = pb else { return }
            CVPixelBufferLockBaseAddress(buf, [])
            let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buf), width: Int(OW), height: Int(OH), bitsPerComponent: 8,
                                bytesPerRow: CVPixelBufferGetBytesPerRow(buf), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: OW, height: OH))
            CVPixelBufferUnlockBaseAddress(buf, [])
            adaptor.append(buf, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: FPS))
        }
        if i % 120 == 0 { print("\(i)/\(frames)") }
    }
    input.markAsFinished()
    let done = DispatchSemaphore(value: 0)
    writer.finishWriting { done.signal() }
    done.wait()
    print("wrote \(outPath) status \(writer.status.rawValue) \(writer.error?.localizedDescription ?? "")")
}
