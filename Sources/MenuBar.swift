// Menu bar gauge: a tiny 5-slice session ring + percentage. Click to open the full widget.

import AppKit
import Combine
import SwiftUI

@MainActor
final class MenuBarController: NSObject {
    private var item: NSStatusItem?
    private var shown: Bool?             // cached state; guards against re-entrant defaults notifications
    private var lastUsage: Usage?
    private let popover = NSPopover()
    private var cancellable: AnyCancellable?
    private var defaultsObserver: NSObjectProtocol?

    init(store: UsageStore, content: NSViewController) {
        super.init()
        popover.contentViewController = content
        popover.behavior = .transient
        popover.animates = true

        lastUsage = store.usage
        cancellable = store.$usage.receive(on: RunLoop.main).sink { [weak self] u in self?.update(u) }

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
                button.action = #selector(toggle)
                button.imagePosition = .imageLeading
                button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
                button.toolTip = "Claude session usage"
            }
            item = it
            update(lastUsage)
        } else if let it = item {
            popover.performClose(nil)
            item = nil
            NSStatusBar.system.removeStatusItem(it)
        }
    }

    private func update(_ u: Usage?) {
        lastUsage = u
        guard let item else { return }
        let pct = u?.five_hour?.utilization
        item.button?.image = Self.gaugeImage(pct)
        item.button?.title = pct.map { " \(Int($0.rounded()))%" } ?? ""
        if let u {
            item.button?.toolTip = "Session \(Int(u.five_hour?.utilization ?? 0))% · Weekly \(Int(u.seven_day?.utilization ?? 0))%"
        }
    }

    @objc private func toggle() {
        guard let button = item?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            NSApp.activate()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
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
