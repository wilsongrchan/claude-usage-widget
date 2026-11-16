// Menu bar gauge: a tiny 5-slice session ring + percentage. Click to open the full widget.

import AppKit
import Combine
import SwiftUI

@MainActor
final class MenuBarController: NSObject {
    private var item: NSStatusItem?
    private var shown: Bool?             // cached state; guards against re-entrant defaults notifications
    private var lastUsage: Usage?
    private var lastProblem: UsageProblem?
    private let popover = NSPopover()
    private let store: UsageStore
    private var cancellable: AnyCancellable?
    private var defaultsObserver: NSObjectProtocol?
    private var outsideClickMonitor: Any?

    init(store: UsageStore, content: NSViewController) {
        self.store = store
        super.init()
        popover.contentViewController = content
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        lastUsage = store.usage
        lastProblem = store.problem
        cancellable = store.$usage.combineLatest(store.$problem).receive(on: RunLoop.main)
            .sink { [weak self] u, p in self?.update(u, p) }

        syncVisibility()
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncVisibility() }
        }
    }

    /// Creates or removes the status item. (Toggling `isVisible` writes to UserDefaults, which
    /// re-triggers this observer and recursed until the app crashed, so we add/remove instead.)
    private func syncVisibility() {
        let show = UserDefaults.standard.object(forKey: "menuBar") as? Bool ?? true
        guard show != shown else { return }
        shown = show
        if show {
            let it = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            if let button = it.button {
                button.target = self
                button.action = #selector(clicked)
                button.sendAction(on: [.leftMouseUp, .rightMouseUp])
                button.imagePosition = .imageLeading
                button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
                button.toolTip = "Claude session usage"
            }
            item = it
            update(lastUsage, lastProblem)
        } else if let it = item {
            popover.performClose(nil)
            item = nil
            NSStatusBar.system.removeStatusItem(it)
        }
    }

    private func update(_ u: Usage?, _ problem: UsageProblem?) {
        lastUsage = u
        lastProblem = problem
        guard let item else { return }
        let pct = u?.five_hour?.utilization
        item.button?.image = Self.gaugeImage(pct)
        item.button?.title = pct.map { " \(Int($0.rounded()))%" } ?? ""
        var tip = u.map { "Session \(Int($0.five_hour?.utilization ?? 0))% · Weekly \(Int($0.seven_day?.utilization ?? 0))%" }
        if let problem { tip = [tip, "⚠︎ \(problem.short)"].compactMap { $0 }.joined(separator: "\n") }
        item.button?.toolTip = tip ?? "Claude session usage"
    }

    /// Popovers from the menu bar follow the menu bar's look (set by the wallpaper), not the
    /// app's, so pass the Theme setting on explicitly (Auto = the system's light/dark).
    func applyTheme() {
        popover.appearance = NSApp.appearance
            ?? NSAppearance(named: NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) ?? .aqua)
    }

    /// Left-click: the popover. Right-click or Control-click: the same menu as the widget's.
    @objc private func clicked() {
        let e = NSApp.currentEvent
        if e?.type == .rightMouseUp || e?.modifierFlags.contains(.control) == true {
            guard let item else { return }
            popover.performClose(nil)
            item.menu = AppMenu.contextMenu(store: store, forMenuBar: true)
            item.button?.performClick(nil)   // shows the menu in the standard menu bar style
            item.menu = nil                  // so the next left-click opens the popover again
        } else if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    func showPopover() {
        guard let button = item?.button, !popover.isShown else { return }
        NSApp.activate()
        applyTheme()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // `.transient` misses clicks on the desktop or in other apps (this app is rarely
        // the active one), so watch for them while the popover is open.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.popover.performClose(nil) }
        }
    }

    /// 16pt 5-slice ring filled to `pct` in the usage colour, with an adaptive grey track.
    static func gaugeImage(_ pct: Double?) -> NSImage {
        let img = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { _ in
            let c = NSPoint(x: 8, y: 8), r: CGFloat = 6, w: CGFloat = 2.6, g = 0.022
            let p = min(max((pct ?? 0) / 100, 0), 1)
            let fill = NSColor(usageColor(pct ?? 0))
            func arc(_ from: Double, _ to: Double, _ col: NSColor) {
                let path = NSBezierPath()
                path.appendArc(withCenter: c, radius: r, startAngle: 90 - from * 360,
                               endAngle: 90 - to * 360, clockwise: true)
                path.lineWidth = w
                col.setStroke()
                path.stroke()
            }
            for k in 0..<5 {
                let a = Double(k) / 5 + g, b = Double(k + 1) / 5 - g
                arc(a, b, NSColor.labelColor.withAlphaComponent(0.25))
                if p > a { arc(a, min(b, p), fill) }
            }
            return true
        }
        img.isTemplate = false
        return img
    }
}

extension MenuBarController: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        if let m = outsideClickMonitor { NSEvent.removeMonitor(m) }
        outsideClickMonitor = nil
    }
}
