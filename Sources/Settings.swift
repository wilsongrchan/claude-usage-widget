// In-widget panels: Settings → Rings / Widget / Alerts / Data / About, and Saved resets.
// Everything renders inside the widget; no OS menus or popovers.

import AppKit
import SwiftUI

enum Panel { case settings, appearance, alerts, data, resets, about }

/// Simple push/pop navigation between panels.
struct Nav {
    let push: (Panel) -> Void
    let pop: () -> Void
}

struct PanelHeader: View {
    let title: String
    let onBack: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 22, height: 22)
                    .foregroundStyle(Color.secondary)
                    .background(Circle().fill(Color.primary.opacity(0.07)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Back")
            .accessibilityLabel("Back")
            Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            Spacer()
        }
    }
}

struct PillButton: View {
    let title: String
    var prominent = false
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .foregroundStyle(prominent ? Color.white : (disabled ? Color.secondary : Color.primary))
                .background(Capsule().fill(prominent ? Palette.claude : Color.primary.opacity(0.08)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
    }
}

/// On/off switch that keeps its colour: system switches turn grey whenever the app isn't
/// frontmost, which for a desktop widget and menu bar popover is nearly always.
struct PillSwitch: ToggleStyle {
    func makeBody(configuration c: Configuration) -> some View {
        Button { withAnimation(.easeOut(duration: 0.15)) { c.isOn.toggle() } } label: {
            ZStack(alignment: c.isOn ? .trailing : .leading) {
                Capsule().fill(c.isOn ? AnyShapeStyle(Palette.claude) : AnyShapeStyle(Color.primary.opacity(0.18)))
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.2), radius: 0.5, y: 0.5)
                    .padding(1.5)
            }
            .frame(width: 28, height: 16)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        // VoiceOver: a standard switch with the toggle's label, reporting on/off.
        .accessibilityRepresentation { Toggle(isOn: c.$isOn) { c.label } }
    }
}

struct SettingToggle<Glyph: View>: View {
    let title: String
    @Binding var isOn: Bool
    @ViewBuilder let glyph: () -> Glyph

    var body: some View {
        HStack(spacing: 8) {
            glyph()
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isOn ? Palette.claude : Color.secondary)
                .frame(width: 16)
                .accessibilityHidden(true)   // decoration; the switch carries the name
            Text(title)
                .font(.system(size: 12))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 4)
            Toggle(title, isOn: $isOn)
                .toggleStyle(PillSwitch())
                .labelsHidden()
        }
    }
}

/// Row that navigates into a sub-panel.
struct NavRow<Glyph: View>: View {
    @Environment(\.colorSchemeContrast) private var contrast
    let title: String
    let subtitle: String
    let action: () -> Void
    @ViewBuilder let glyph: () -> Glyph

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                glyph()
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.claude)
                    .frame(width: 26, height: 26)
                    .accessibilityHidden(true)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Palette.claude.opacity(0.14)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 12, weight: .semibold))
                    Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(contrast == .increased ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Label above a full-width segmented picker (fits both widget sizes).
struct LabeledPicker<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(String, Value)]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            // Custom segmented control: the system one always highlights in blue.
            HStack(spacing: 2) {
                ForEach(Array(options.enumerated()), id: \.offset) { _, o in
                    let selected = selection == o.1
                    Button { withAnimation(.easeOut(duration: 0.15)) { selection = o.1 } } label: {
                        Text(o.0)
                            .font(.system(size: 11, weight: selected ? .semibold : .regular))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .foregroundStyle(selected ? Palette.claude : Color.primary.opacity(0.75))
                            .frame(maxWidth: .infinity)
                            .frame(height: 20)
                            .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(selected ? Palette.claude.opacity(0.18) : Color.clear))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.06)))
            .accessibilityElement(children: .contain)
            .accessibilityLabel(title)
        }
    }
}

struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .textCase(.uppercase)
            .tracking(0.8)
            .foregroundStyle(.secondary)
            .padding(.top, 2)
    }
}


func onOff(_ b: Bool) -> String { b ? "on" : "off" }

// MARK: - Settings (tabbed)

struct SettingsPanel: View {
    @ObservedObject var store: UsageStore
    let nav: Nav
    let allowSize: Bool
    var onLevelChange: (Bool) -> Void
    var onSizeChange: (Bool) -> Void
    @AppStorage("settingsTab") var tab = 0

    static let tabs: [(title: String, short: String, icon: String)] = [
        ("Rings", "Rings", "circle.dashed"), ("Widget", "Widget", "paintpalette"),
        ("Alerts", "Alerts", "bell"), ("Data", "Data", "chart.pie"), ("About & privacy", "About", "info.circle"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Preferences-style toolbar: icon above label, selected item highlighted.
            VStack(spacing: 6) {
                HStack(alignment: .top, spacing: 0) {
                    Button(action: nav.pop) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 10, weight: .bold))
                            .frame(width: 20, height: 38)
                            .foregroundStyle(Color.secondary)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Back to widget")
                    .accessibilityLabel("Back to widget")
                    Spacer(minLength: 0)
                    ForEach(Self.tabs.indices, id: \.self) { i in
                        let selected = tab == i
                        Button { withAnimation(.easeOut(duration: 0.15)) { tab = i } } label: {
                            VStack(spacing: 2) {
                                Image(systemName: Self.tabs[i].icon)
                                    .font(.system(size: 15, weight: .regular))
                                    .frame(height: 18)
                                Text(Self.tabs[i].short)
                                    .font(.system(size: 10, weight: selected ? .semibold : .regular))
                                    .lineLimit(1)
                                    .fixedSize()
                            }
                            .foregroundStyle(selected ? Palette.claude : Color.secondary)
                            .frame(width: 58)   // equal-width tabs (five fit the large widget)
                            .padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(selected ? Color.primary.opacity(0.09) : Color.clear))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(Self.tabs[i].title)
                        .accessibilityLabel(Self.tabs[i].title)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                        Spacer(minLength: 0)
                    }
                }
                Divider()
            }

            switch tab {
            case 1: AppearancePanel(nav: nav, allowSize: allowSize, onLevelChange: onLevelChange,
                                    onSizeChange: onSizeChange, showHeader: false)
            case 2: AlertsPanel(nav: nav, showHeader: false)
            case 3: DataPanel(store: store, nav: nav, showHeader: false)
            case 4: AboutPanel(nav: nav, showHeader: false, store: store)
            default: RingsPanel()
            }
        }
    }
}

// MARK: - Rings

/// Everything about the rings themselves and the notes under them.
struct RingsPanel: View {
    @AppStorage("showPaceMarker") var showPaceMarker = true
    @AppStorage("segmentedRings") var segmentedRings = true
    @AppStorage("weeklySplit") var weeklySplit = 0
    @AppStorage("showScoped") var showScoped = true
    @AppStorage("showPaceNote") var showPaceNote = true
    @AppStorage("showForecast") var showForecast = true
    @State private var custom: [Double] = WeekBudget.custom

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: "Rings")
                SettingToggle(title: "Pace marker", isOn: $showPaceMarker) { PaceGlyph() }
                SettingToggle(title: "Segmented rings", isOn: $segmentedRings) { SegmentGlyph() }
                // Sub-option of Segmented rings: how the weekly ring's slices (and pace) are split.
                HStack(alignment: .top, spacing: 8) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Palette.claude.opacity(0.35))
                        .frame(width: 2)
                        .padding(.leading, 7)
                    VStack(alignment: .leading, spacing: 6) {
                        LabeledPicker(title: "Weekly ring slices", selection: $weeklySplit,
                                      options: [("7 days", 0), ("Weekdays", 1), ("Custom", 2), ("Rest evenly", 3)])
                        Text(weeklySplit == 0 ? "Even split: about 14% per day."
                             : weeklySplit == 1 ? "5 slices, 20% per weekday; weekends get no budget."
                             : weeklySplit == 2 ? "Set each day's share. Slices and pace follow it."
                             : "What's left is shared evenly by today and the days still to come. Days already gone become one slice of what they used.")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if weeklySplit == 2 { customEditor }
                    }
                }
                .opacity(segmentedRings ? 1 : 0.5)
                SettingToggle(title: "Model limit bar", isOn: $showScoped) { Image(systemName: "chart.bar.fill") }

                SectionLabel(text: "Notes")
                SettingToggle(title: "Pace note", isOn: $showPaceNote) { Image(systemName: "checkmark.circle") }
                SettingToggle(title: "Run-out estimate", isOn: $showForecast) { Image(systemName: "hourglass") }
            }
            .padding(.bottom, 2)
        }
    }

    var customEditor: some View {
        let total = custom.reduce(0, +)
        return VStack(spacing: 5) {
            ForEach(0..<7, id: \.self) { i in
                HStack(spacing: 6) {
                    Text(WeekBudget.dayNames[i])
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 30, alignment: .leading)
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Palette.claude.opacity(0.14))
                            Capsule().fill(Palette.claude)
                                .frame(width: g.size.width * min(custom[i] / max(total, 1), 1))
                        }
                    }
                    .frame(height: 5)
                    stepper("minus") { set(i, custom[i] - 1) }
                    Text("\(Int(custom[i]))%")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .frame(width: 32)
                    stepper("plus") { set(i, custom[i] + 1) }
                }
            }
            HStack {
                Text("Total \(Int(total))%")
                    .font(.system(size: 10, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Int(total) == 100 ? Color.secondary : Palette.ember)
                if Int(total) != 100 {
                    Text("(scaled to 100%)").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Reset") { custom = WeekBudget.defaultCustom; save() }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.claude)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
    }

    func set(_ i: Int, _ v: Double) {
        custom[i] = min(max(v, 0), 100)
        save()
    }

    func save() { UserDefaults.standard.set(custom, forKey: "customAlloc") }

    func stepper(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 8, weight: .bold))
                .frame(width: 16, height: 16)
                .foregroundStyle(Palette.claude)
                .background(Circle().fill(Palette.claude.opacity(0.15)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(icon == "minus" ? "Decrease" : "Increase")
        .buttonRepeatBehavior(.enabled)
    }
}

// MARK: - Widget (look, size, where it shows)

struct AppearancePanel: View {
    let nav: Nav
    let allowSize: Bool
    var onLevelChange: (Bool) -> Void
    var onSizeChange: (Bool) -> Void

    @AppStorage("theme") var theme = 0
    @AppStorage("widgetStyle") var widgetStyle = 0
    @AppStorage(WidgetSize.key) var sizeRaw = WidgetSize.current.rawValue
    @AppStorage("shrinkDown") var shrinkDown = false     // large ↔ medium: keep the bottom edge
    @AppStorage("shrinkRight") var shrinkRight = false   // medium ↔ small: keep the right edge
    @AppStorage("showWidget") var showWidget = true
    @AppStorage("menuBar") var menuBar = true
    @AppStorage("floatOnTop") var floatOnTop = false

    var showHeader = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showHeader { PanelHeader(title: "Widget", onBack: nav.pop) }
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 10) {
                    // Pairs side by side so the whole tab needs little scrolling.
                    HStack(alignment: .top, spacing: 12) {
                        LabeledPicker(title: "Theme", selection: $theme,
                                      options: [("Auto", 0), ("Light", 1), ("Dark", 2)])
                        LabeledPicker(title: "Color style", selection: $widgetStyle,
                                      options: [("Auto", 0), ("Color", 1), ("Mono", 2)])
                    }
                    Text(widgetStyle == 0 ? "Color style Auto: fades like desktop widgets while you're in an app; full color when you click the desktop."
                         : widgetStyle == 1 ? "Always full color." : "Always translucent and monochrome.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if allowSize {
                        HStack(alignment: .top, spacing: 12) {
                            LabeledPicker(title: "Size", selection: Binding(
                                get: { sizeRaw }, set: { v in
                                    WidgetSize.noteChange(from: sizeRaw, to: v)
                                    withAnimation(WidgetSize.changeAnimation) { sizeRaw = v }
                                    onSizeChange(true) }),
                                          options: WidgetSize.allCases.map { ($0.name, $0.rawValue) })
                            // Which way it shrinks (growing goes back the same way).
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Resize direction").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                                HStack(alignment: .top, spacing: 8) {
                                    VStack(spacing: 3) {
                                        IconChoice(selection: $shrinkDown, options: [
                                            (false, "Large → medium shrinks up", AnyView(ShrinkGlyph(vertical: true, toEnd: false))),
                                            (true, "Large → medium shrinks down", AnyView(ShrinkGlyph(vertical: true, toEnd: true))),
                                        ])
                                        Text("Large ↔ medium").font(.system(size: 10)).foregroundStyle(.secondary)
                                    }
                                    VStack(spacing: 3) {
                                        IconChoice(selection: $shrinkRight, options: [
                                            (false, "Medium → small shrinks left", AnyView(ShrinkGlyph(vertical: false, toEnd: false))),
                                            (true, "Medium → small shrinks right", AnyView(ShrinkGlyph(vertical: false, toEnd: true))),
                                        ])
                                        Text("Medium ↔ small").font(.system(size: 10)).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .fixedSize()
                        }
                    }

                    SectionLabel(text: "Window")
                    SettingToggle(title: "Desktop widget", isOn: Binding(
                        get: { showWidget }, set: { v in if !v { menuBar = true }; showWidget = v })) {
                        Image(systemName: "rectangle.on.rectangle")
                    }
                    SettingToggle(title: "Menu bar gauge", isOn: Binding(
                        get: { menuBar }, set: { v in if !v { showWidget = true }; menuBar = v })) {
                        Image(systemName: "menubar.rectangle")
                    }
                    SettingToggle(title: "Float above windows", isOn: Binding(
                        get: { floatOnTop }, set: { floatOnTop = $0; onLevelChange($0) })) {
                        Image(systemName: "square.stack")
                    }
                    OpenAtLoginToggle()
                }
                .padding(.bottom, 2)
            }
        }
    }
}

// MARK: - Alerts

struct AlertsPanel: View {
    let nav: Nav
    var showHeader = true
    @AppStorage("sessionResetAlert") var sessionResetAlert = true
    @AppStorage("resetReminders") var resetReminders = true
    @AppStorage("resetCount") var resetCount = 0
    @AppStorage(UpdateChecker.enabledKey) var checkUpdates = true
    @State private var notificationsDenied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showHeader { PanelHeader(title: "Alerts", onBack: nav.pop) }
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    if notificationsDenied {
                        // Otherwise every alert below would fail silently.
                        HStack(spacing: 6) {
                            Image(systemName: "bell.slash").foregroundStyle(Palette.ember)
                            Text("Notifications are off for Claude Usage")
                                .lineLimit(1).minimumScaleFactor(0.8)
                            Spacer(minLength: 4)
                            Button("Turn On…") { NSWorkspace.shared.open(NotificationAccess.settingsURL) }
                                .buttonStyle(.plain)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Palette.claude)
                        }
                        .font(.system(size: 11))
                    }
                    SectionLabel(text: "Usage alerts")
                    ForEach(LimitAlerts.groups, id: \.key) { g in
                        ThresholdEditor(key: g.key, title: g.title, subtitle: g.subtitle)
                    }
                    SectionLabel(text: "Other")
                    SettingToggle(title: "Session reset (if 50%+ used)",
                                  isOn: Binding(get: { sessionResetAlert }, set: {
                                      sessionResetAlert = $0
                                      if $0 { NotificationAccess.requestIfUndetermined() }
                                  })) { SessionResetGlyph() }
                    ReminderEditor()
                    NavRow(title: "Saved resets", subtitle: resetCount > 0 ? "\(resetCount) saved" : "None tracked",
                           action: { nav.push(.resets) }) { SessionResetGlyph().scaleEffect(0.85) }
                    // Off = no daily GitHub check at all (About can still check by hand).
                    SettingToggle(title: "Update notifications", isOn: Binding(
                        get: { checkUpdates }, set: { v in
                            checkUpdates = v
                            if v { UpdateChecker.shared.checkIfDue() }
                        })) { Image(systemName: "arrow.down.circle") }
                }
                .padding(.bottom, 2)
            }
        }
        .task { await checkNotifications() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await checkNotifications() }
        }
        // Coming back from System Settings doesn't activate this app, so look again on hover too.
        .onHover { if $0 { Task { await checkNotifications() } } }
    }

    func checkNotifications() async {
        notificationsDenied = await NotificationAccess.status() == .denied
    }
}

/// One limit's alert settings: on/off plus removable threshold chips and a "+" to add more.
struct ThresholdEditor: View {
    let key: String
    let title: String
    let subtitle: String
    @State private var thresholds: [Int] = []
    @State private var enabled = true
    @State private var adding = false
    @State private var newValue = 90

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(.system(size: 12, weight: .semibold))
                    Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Toggle(title, isOn: Binding(get: { enabled }, set: {
                    enabled = $0; save()
                    if $0 { NotificationAccess.requestIfUndetermined() }
                }))
                    .toggleStyle(PillSwitch())
                    .labelsHidden()
            }
            if enabled {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 50), spacing: 5)], alignment: .leading, spacing: 5) {
                    ForEach(thresholds, id: \.self) { t in
                        HStack(spacing: 3) {
                            Text("\(t)%").monospacedDigit()
                            Button { thresholds.removeAll { $0 == t }; save() } label: {
                                Image(systemName: "xmark").font(.system(size: 7, weight: .bold))
                            }
                            .buttonStyle(.plain)
                            .help("Remove \(t)% alert")
                            .accessibilityLabel("Remove \(t)% alert")
                        }
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Palette.claude)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Palette.claude.opacity(0.15)))
                    }
                    if !adding {
                        Button {
                            newValue = min((thresholds.max() ?? 85) + 1, 99)
                            if thresholds.contains(newValue) { newValue = 90 }
                            adding = true
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 9, weight: .bold))
                                .frame(width: 28, height: 19)
                                .foregroundStyle(Palette.claude)
                                .background(Capsule().strokeBorder(Palette.claude.opacity(0.5),
                                                                   style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .help("Add an alert threshold")
                        .accessibilityLabel("Add an alert threshold")
                    }
                }
                if adding {
                    HStack(spacing: 5) {
                        step("minus") { newValue = max(newValue - 1, 1) }
                        Text("\(newValue)%")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .frame(width: 36)
                        step("plus") { newValue = min(newValue + 1, 100) }
                        Spacer(minLength: 2)
                        PillButton(title: "Add", prominent: true, disabled: thresholds.contains(newValue)) {
                            thresholds.append(newValue); thresholds.sort(); adding = false; save()
                        }
                        Button { adding = false } label: {
                            Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Cancel")
                    }
                }
                if thresholds.isEmpty && !adding {
                    Text("No thresholds. Tap + to add one.").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
        .onAppear {
            thresholds = LimitAlerts.thresholds(key)
            enabled = LimitAlerts.enabled(key)
        }
    }

    func save() {
        UserDefaults.standard.set(thresholds, forKey: "alertThresholds.\(key)")
        UserDefaults.standard.set(enabled, forKey: "alertEnabled.\(key)")
    }

    func step(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 8, weight: .bold))
                .frame(width: 18, height: 18)
                .foregroundStyle(Palette.claude)
                .background(Circle().fill(Palette.claude.opacity(0.15)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(icon == "minus" ? "Decrease" : "Increase")
        .buttonRepeatBehavior(.enabled)
    }
}

/// When to be reminded before a saved reset expires: removable chips plus "+" (hours or days).
struct ReminderEditor: View {
    @AppStorage("resetReminders") var enabled = true
    @State private var leads: [Int] = []
    @State private var adding = false
    @State private var value = 2
    @State private var inDays = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Saved-reset reminders").font(.system(size: 12, weight: .semibold))
                    Text("How long before a saved reset expires").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Toggle("Saved-reset reminders", isOn: Binding(get: { enabled }, set: {
                    enabled = $0
                    if $0 { NotificationAccess.requestIfUndetermined() }
                }))
                    .toggleStyle(PillSwitch())
                    .labelsHidden()
            }
            if enabled {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 46), spacing: 5)], alignment: .leading, spacing: 5) {
                    ForEach(leads.sorted(by: >), id: \.self) { l in
                        HStack(spacing: 3) {
                            Text(ResetReminder.leadText(l)).monospacedDigit()
                            Button { leads.removeAll { $0 == l }; save() } label: {
                                Image(systemName: "xmark").font(.system(size: 7, weight: .bold))
                            }
                            .buttonStyle(.plain)
                            .help("Remove the \(ResetReminder.leadText(l, long: true)) reminder")
                            .accessibilityLabel("Remove the \(ResetReminder.leadText(l, long: true)) reminder")
                        }
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Palette.claude)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Palette.claude.opacity(0.15)))
                    }
                    if !adding {
                        Button { adding = true } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 9, weight: .bold))
                                .frame(width: 28, height: 19)
                                .foregroundStyle(Palette.claude)
                                .background(Capsule().strokeBorder(Palette.claude.opacity(0.5),
                                                                   style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .help("Add a reminder")
                        .accessibilityLabel("Add a reminder")
                    }
                }
                if adding {
                    let secs = value * (inDays ? 86400 : 3600)
                    HStack(spacing: 5) {
                        step("minus") { value = max(value - 1, 1) }
                        Text("\(value)")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .frame(width: 22)
                        step("plus") { value = min(value + 1, inDays ? 30 : 72) }
                        Button { inDays.toggle(); value = min(value, inDays ? 30 : 72) } label: {
                            Text(inDays ? "days" : "hours")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Palette.claude)
                                .underline()
                        }
                        .buttonStyle(.plain)
                        .help("Switch between hours and days")
                        .accessibilityLabel("Switch between hours and days")
                        Spacer(minLength: 2)
                        PillButton(title: "Add", prominent: true, disabled: leads.contains(secs)) {
                            leads.append(secs); adding = false; save()
                        }
                        Button { adding = false } label: {
                            Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Cancel")
                    }
                }
                if leads.isEmpty && !adding {
                    Text("No reminders. Tap + to add one.").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
        .onAppear { leads = ResetReminder.leads }
    }

    func save() { UserDefaults.standard.set(leads.sorted(), forKey: "resetReminderLeads") }

    func step(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 8, weight: .bold))
                .frame(width: 18, height: 18)
                .foregroundStyle(Palette.claude)
                .background(Circle().fill(Palette.claude.opacity(0.15)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .buttonRepeatBehavior(.enabled)
    }
}

/// 4-point spark with a pinched waist — reads clearly as a star at icon sizes.
struct SparkShape: Shape {
    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let R = min(rect.width, rect.height) / 2
        let inner = R * 0.30
        var p = Path()
        for k in 0..<8 {
            let a = Double(k) / 8 * 2 * .pi - .pi / 2
            let r = k % 2 == 0 ? R : inner
            let pt = CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
            if k == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath()
        return p
    }
}

/// Session-reset icon: a looping arrow with a spark inside (distinct from the plain refresh arrow).
struct SessionResetGlyph: View {
    var body: some View {
        ZStack {
            Image(systemName: "arrow.trianglehead.clockwise")
                .font(.system(size: 14, weight: .semibold))
            SparkShape()
                .frame(width: 10.5, height: 10.5)
        }
        .frame(width: 16, height: 16)
    }
}

// MARK: - Data

struct DataPanel: View {
    @ObservedObject var store: UsageStore
    let nav: Nav

    var showHeader = true

    var body: some View {
        let hours = HourlyLog.today(store.now)
        let total = hours.reduce(0, +)
        let nowHour = Calendar.current.component(.hour, from: store.now)
        let busiest = hours.indices.max { hours[$0] < hours[$1] }

        VStack(alignment: .leading, spacing: 8) {
            if showHeader { PanelHeader(title: "Data", onBack: nav.pop) }
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 5) {
                        if let age = ageText(store.lastUpdated, now: store.now) {
                            Text("Updated \(age)")
                                .font(.system(size: 10, weight: .medium))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        RefreshButton(store: store)
                        Spacer(minLength: 0)
                    }
                    HStack(alignment: .center, spacing: 6) {
                        RoseDiagram(values: hours, currentHour: nowHour, diameter: 128,
                                    centerValue: "\(Int(total.rounded()))%", centerLabel: "today")
                        VStack(alignment: .leading, spacing: 8) {
                            if let b = busiest, hours[b] > 0 {
                                stat("Busiest hour today", hourLabel(b), note: "\(Int(hours[b].rounded()))%")
                            }
                            stat("This hour", "\(Int(hours[nowHour].rounded()))%")
                        }
                        Spacer(minLength: 0)
                    }
                    Text("Session usage per hour today (centre: total, as % of one session), recorded while the widget runs. Midnight at top.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let rows = store.usage?.seven_day_breakdown?.rows, !rows.isEmpty {
                        SectionLabel(text: "This week by app")
                        VStack(spacing: 6) {
                            ForEach(Array(rows.filter { ($0.percent ?? 0) > 0 }.enumerated()), id: \.offset) { _, r in
                                BarRow(label: r.display_name ?? "Other", percent: r.percent ?? 0)
                            }
                        }
                    }
                }
            }
        }
    }

    /// "2 PM" or "14:00", following the Mac's 12/24-hour setting (like the forecast times).
    func hourLabel(_ h: Int) -> String {
        if uses24Hour { return "\(h):00" }
        let h12 = h % 12 == 0 ? 12 : h % 12
        return "\(h12) \(h < 12 ? "AM" : "PM")"
    }

    func stat(_ title: String, _ value: String, note: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit()
                if let note { Text(note).font(.system(size: 10)).foregroundStyle(.secondary) }
            }
        }
    }
}

// MARK: - Saved resets

struct ResetPanel: View {
    let now: Date
    let nav: Nav

    @AppStorage("resetCount") var count = 0
    @AppStorage("resetExpiry") var expiry: Double = 0   // 0 = not set

    var body: some View {
        let remaining = expiry - now.timeIntervalSince1970

        VStack(alignment: .leading, spacing: 10) {
            PanelHeader(title: "Saved limit resets", onBack: nav.pop)
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Text("Available").font(.system(size: 12))
                        Spacer(minLength: 4)
                        stepButton("minus") { count = max(count - 1, 0) }
                        Text("\(count)")
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .frame(minWidth: 18)
                        stepButton("plus") { count = min(count + 1, 20); ResetReminder.check() }
                    }

                    let picker = DatePicker("", selection: Binding(
                        get: { Date(timeIntervalSince1970: expiry) },
                        set: { expiry = $0.timeIntervalSince1970 }),
                                            displayedComponents: [.date, .hourAndMinute])
                        .datePickerStyle(.field)
                        .labelsHidden()
                        .controlSize(.small)
                    if expiry <= 0 {
                        // No expiry until you set one; the picker then starts 30 days out.
                        HStack {
                            Text("Expires").font(.system(size: 12))
                            Spacer()
                            PillButton(title: "Set expiry") {
                                expiry = Date().addingTimeInterval(30 * 86400).timeIntervalSince1970
                                ResetReminder.check()
                            }
                        }
                    } else {
                        HStack {
                            Text("Expires").font(.system(size: 12))
                            Spacer()
                            picker.fixedSize()
                        }
                    }

                    if count > 0 && expiry <= 0 {
                        Text("No reminders until you set an expiry.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    } else if count > 0 {
                        Text(remaining > 0 ? "Expires in \(ResetReminder.remainingText(remaining))" : "Expired")
                            .font(.system(size: 11, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(ResetReminder.color(remaining))
                    }

                    HStack {
                        PillButton(title: "Used one", disabled: count == 0) { count = max(count - 1, 0) }
                        Spacer()
                        PillButton(title: "Open usage ↗", prominent: true) {
                            NSWorkspace.shared.open(ResetReminder.settingsURL)
                        }
                    }

                    Text("Claude's usage API doesn't report resets, so enter them from Settings → Usage. Reminders arrive \(ResetReminder.leadsSummary) before expiry (change in Alerts).")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    func stepButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .bold))
                .frame(width: 22, height: 22)
                .foregroundStyle(Palette.claude)
                .background(Circle().fill(Palette.claude.opacity(0.15)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(icon == "minus" ? "Decrease" : "Increase")
    }
}

// MARK: - About & privacy

struct AboutPanel: View {
    let nav: Nav

    var showHeader = true

    var store: UsageStore? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showHeader { PanelHeader(title: "About & privacy", onBack: nav.pop) }
            ScrollView(showsIndicators: true) {
                VStack(alignment: .leading, spacing: 12) {
                    VersionSection()
                    Divider().padding(.vertical, 2)
                    section("Unofficial app", icon: "exclamationmark.shield",
                            "Claude Usage is an independent, unofficial project. It is not made by, affiliated with, or endorsed by Anthropic. \"Claude\" and \"Anthropic\" are trademarks of Anthropic, PBC, used here only to describe what the app shows.")
                    section("Your data stays on this Mac", icon: "lock",
                            "There is no server of ours, no account, no analytics and no tracking. The app reads your existing Claude Code login from the macOS Keychain and uses it only to ask Anthropic's own API (api.anthropic.com) for your usage. The login token is never saved, logged or sent anywhere else. Separately, once a day it asks GitHub whether a newer version is out; that request carries no personal data, and you can turn it off in Alerts.")
                    section("Keychain access", icon: "key",
                            "macOS asks whether \u{201C}security\u{201D} may use \u{201C}Claude Code-credentials\u{201D}: that's how the app reads your Claude Code login. Always Allow stops macOS asking again, but it also lets other software on this Mac read that login through the same system tool. Allow asks again each time the app re-reads the login (at launch, and when Claude Code renews its login).")
                    section("What's stored locally", icon: "internaldrive",
                            "Your settings, saved-reset count and expiry, and today's hourly usage are kept in this Mac's app preferences. Nothing leaves your Mac except that usage request to Anthropic and the daily update check with GitHub.")
                    section("Accuracy", icon: "info.circle",
                            "Usage comes from an undocumented Anthropic endpoint that may change or stop working. Forecasts are estimates. Check Settings → Usage on claude.ai for the official figures.")
                    section("No warranty", icon: "doc.text",
                            "Provided \"as is\", without warranty of any kind, express or implied, including accuracy, reliability or fitness for a particular purpose.")
                    section("Limitation of liability", icon: "exclamationmark.triangle",
                            "To the fullest extent permitted by law, the authors are not liable for any loss or damage arising from using this app, including: inaccurate, delayed or missing usage figures or forecasts; missed, late or incorrect alerts and reminders; reaching or exceeding Claude usage limits; unused or expired saved resets; lost work, data or settings; or any charges, restrictions or account issues with Anthropic. You use it entirely at your own risk.")
                    Divider().padding(.vertical, 2)
                    HStack {
                        PillButton(title: "Refresh") { Task { await store?.refresh(userInitiated: true) } }
                        Spacer()
                        PillButton(title: "Quit") { NSApp.terminate(nil) }
                    }
                }
                .padding(.bottom, 4)
            }
        }
    }

    func section(_ title: String, icon: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.claude)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}


// MARK: - Shrink direction

/// Diagram of a shrink: dashed outline = the size before, solid block = where the widget ends up.
/// Vertical: large → medium, keeping the top (or bottom). Horizontal: medium → small, keeping the left (or right).
struct ShrinkGlyph: View {
    let vertical: Bool
    let toEnd: Bool     // down / right
    var scale: CGFloat = 1

    var body: some View {
        let u: CGFloat = 8 * scale, gap: CGFloat = 1.5 * scale, r: CGFloat = 2.5 * scale
        let outer = CGSize(width: 2 * u + gap, height: vertical ? 2 * u + gap : u)
        let inner = CGSize(width: vertical ? outer.width : u, height: u)
        let align: Alignment = vertical ? (toEnd ? .bottom : .top) : (toEnd ? .trailing : .leading)
        ZStack(alignment: align) {
            RoundedRectangle(cornerRadius: r, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [2, 1.5]))
                .opacity(0.55)
                .frame(width: outer.width, height: outer.height)
            RoundedRectangle(cornerRadius: r, style: .continuous)
                .frame(width: inner.width, height: inner.height)
        }
        .frame(width: outer.width, height: outer.height)
    }
}

/// Segmented choice with drawn icons (system segmented pickers only take text or SF Symbols).
struct IconChoice<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, String, AnyView)]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, o in
                let selected = selection == o.0
                Button { withAnimation(.easeOut(duration: 0.15)) { selection = o.0 } } label: {
                    o.2
                        .foregroundStyle(selected ? Palette.claude : Color.primary.opacity(0.62))
                        .frame(width: 38, height: 30)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(selected ? Palette.claude.opacity(0.18) : Color.clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(o.1)
                .accessibilityLabel(o.1)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))
    }
}
