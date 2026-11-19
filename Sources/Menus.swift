// Standard menus: the right-click menu (widget and menu bar item) and a minimal main menu,
// so Command-Q, Command-W and copy/paste work in the welcome window and text fields.

import AppKit
import SwiftUI

/// A menu item that runs a closure.
final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, key: String = "", image: String? = nil, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        target = self
        if let image { self.image = NSImage(systemSymbolName: image, accessibilityDescription: nil) }
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func fire() { handler() }
}

@MainActor
enum AppMenu {
    /// Refresh · Small / Medium / Large · Settings… · Hide (or Show) Widget · Send Feedback… · Quit.
    /// From the menu bar item, Settings… opens in the popover (the menu bar's own panel).
    static func contextMenu(store: UsageStore?, forMenuBar: Bool) -> NSMenu {
        let menu = NSMenu()
        let d = UserDefaults.standard
        let widgetShown = d.object(forKey: "showWidget") as? Bool ?? true

        let refresh = ActionMenuItem("Refresh", image: "arrow.clockwise") {
            Task { await store?.refresh(userInitiated: true) }
        }
        refresh.isEnabled = !(store?.loading ?? false)
        menu.addItem(refresh)
        menu.addItem(.separator())

        let current = WidgetSize.current
        for s in WidgetSize.allCases {
            let item = ActionMenuItem(s.name) { WidgetCommand.setSize(s).send() }
            item.state = s == current ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())

        menu.addItem(ActionMenuItem("Settings…", key: ",") {
            if forMenuBar || !widgetShown {
                delegate?.menuBar?.showPopover()
                // Give the popover's view a moment to appear before it's told to open settings.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { WidgetCommand.open(.settings, .popover).send() }
            } else {
                WidgetCommand.open(.settings, .widget).send()
            }
        })
        if forMenuBar && !widgetShown {
            menu.addItem(ActionMenuItem("Show Widget", image: "macwindow") { d.set(true, forKey: "showWidget") })
        } else {
            menu.addItem(ActionMenuItem("Hide Widget", image: "menubar.rectangle") { hideWidget() })
        }
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem("Send Feedback…", image: "bubble.left") { AppInfo.sendFeedback() })
        menu.addItem(ActionMenuItem("Quit Claude Usage", key: "q") { NSApp.terminate(nil) })
        return menu
    }

    /// Hide just the desktop widget. The menu bar gauge is turned on so the app never vanishes.
    static func hideWidget() {
        let d = UserDefaults.standard
        d.set(true, forKey: "menuBar")
        d.set(false, forKey: "showWidget")
    }

    static var delegate: AppDelegate? { NSApp.delegate as? AppDelegate }

    static func installMainMenu() {
        let main = NSMenu()

        let app = NSMenu()
        app.addItem(withTitle: "About Claude Usage",
                    action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Claude Usage", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        addSubmenu(app, title: "Claude Usage", to: main)

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        addSubmenu(edit, title: "Edit", to: main)

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        addSubmenu(window, title: "Window", to: main)

        NSApp.mainMenu = main
    }

    private static func addSubmenu(_ menu: NSMenu, title: String, to main: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        main.addItem(item)
    }
}
