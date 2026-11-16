// First-run welcome window, the Open at Login switch, and notification permission.

import AppKit
import ServiceManagement
import SwiftUI
import UserNotifications

// MARK: - Open at Login

/// Backed by SMAppService (works for the ad-hoc signed app; tested on macOS 26). The state
/// always comes from `SMAppService.mainApp.status`, never from our own preferences.
enum LoginItem {
    /// `./build.sh install` used to start the app with this LaunchAgent.
    static let legacyLabel = "local.claude-usage-widget"
    static var legacyAgent: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(legacyLabel).plist")
    }

    static var status: SMAppService.Status { SMAppService.mainApp.status }
    /// Registered, possibly still waiting for approval in System Settings → Login Items.
    static var isOn: Bool { status == .enabled || status == .requiresApproval }
    /// Opened straight from the unzipped folder: macOS runs it from a temporary path that
    /// won't exist at the next login, so registering would do nothing useful.
    static var translocated: Bool { Bundle.main.bundlePath.contains("/AppTranslocation/") }

    static func set(_ on: Bool) throws {
        if on {
            if status != .enabled { try SMAppService.mainApp.register() }
            removeLegacyAgent()   // otherwise it would start twice
        } else if isOn {
            try SMAppService.mainApp.unregister()
        }
    }

    static func removeLegacyAgent() {
        let url = legacyAgent
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        // If that agent started this very process, booting it out would quit us. Deleting the
        // file is enough then: launchd won't load it at the next login.
        if ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] != legacyLabel {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            p.arguments = ["bootout", "gui/\(getuid())", url.path]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            if (try? p.run()) != nil { p.waitUntilExit() }
        }
        try? FileManager.default.removeItem(at: url)
    }
}

struct OpenAtLoginToggle: View {
    @State private var on = LoginItem.isOn
    @State private var status = LoginItem.status
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            SettingToggle(title: "Open at Login", isOn: Binding(get: { on }, set: apply)) {
                Image(systemName: "power")
            }
            .disabled(LoginItem.translocated)
            if let note {
                Text(note)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 24)
            }
            if status == .requiresApproval && !LoginItem.translocated {
                Button("Open Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.claude)
                    .padding(.leading, 24)
            }
        }
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in reload() }
    }

    var note: String? {
        if LoginItem.translocated { return "Move Claude Usage to Applications first." }
        if let failure { return failure }
        if status == .requiresApproval { return "Waiting for approval in System Settings → Login Items." }
        return nil
    }

    func apply(_ v: Bool) {
        do { try LoginItem.set(v); failure = nil }
        catch { failure = "Couldn't change it: \(error.localizedDescription)" }
        reload()
    }

    func reload() { status = LoginItem.status; on = LoginItem.isOn }
}

// MARK: - Notification permission

enum NotificationAccess {
    static var center: UNUserNotificationCenter { .current() }

    static func status() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    @discardableResult
    static func request() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    /// When the user turns an alert on: ask, if macOS hasn't asked yet. (Posting never asks.)
    static func requestIfUndetermined() {
        Task { if await status() == .notDetermined { await request() } }
    }

    static let settingsURL = URL(string:
        "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=local.claude-usage-widget")!
}

// MARK: - Welcome window

/// Shown once, on first launch (`onboarded` not set). The Keychain isn't touched until the
/// user presses Connect (or closes this window, which counts as done).
@MainActor
final class Welcome: NSObject, NSWindowDelegate {
    static let key = "onboarded"
    private static var current: Welcome?

    private let window: NSWindow
    private let store: UsageStore

    /// Existing users (a stored reading is present) are marked onboarded without seeing the window.
    /// Returns true when the welcome window should be shown.
    static func needed() -> Bool {
        let d = UserDefaults.standard
        if d.bool(forKey: key) { return false }
        if d.data(forKey: "lastUsageData") != nil {
            d.set(true, forKey: key)
            // Older versions asked for notification permission at the first alert; posting no
            // longer asks, so ask once now for anyone who was never asked.
            NotificationAccess.requestIfUndetermined()
            return false
        }
        return true
    }

    static func show(store: UsageStore) {
        let w = Welcome(store: store)
        current = w
        w.window.center()
        NSApp.activate()
        w.window.makeKeyAndOrderFront(nil)
    }

    private init(store: UsageStore) {
        self.store = store
        window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable],
                          backing: .buffered, defer: false)
        super.init()
        let view = WelcomeView(store: store, done: { [weak self] in self?.window.close() })
        window.contentViewController = NSHostingController(rootView: view)
        window.title = "Welcome to Claude Usage"
        window.isReleasedWhenClosed = false
        window.delegate = self
    }

    func windowWillClose(_ notification: Notification) {
        UserDefaults.standard.set(true, forKey: Self.key)
        store.allowKeychain()   // closed without connecting: carry on as normal (macOS asks now)
        Self.current = nil
    }
}

struct WelcomeView: View {
    @ObservedObject var store: UsageStore
    let done: () -> Void
    @State private var asked = false
    @State private var notifications: UNAuthorizationStatus?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Welcome to Claude Usage").font(.system(size: 17, weight: .bold))
                    Text("Three quick things and you're set.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }

            row(1, "Connect to Claude Code") {
                Text("The app reads your Claude Code login from the Keychain, so macOS will ask whether “security” may use “Claude Code-credentials”.")
                Text("**Always Allow** stops macOS asking again, but it also lets other software on this Mac read that login through the same system tool. **Allow** asks again each time the app re-reads the login (at launch, and when Claude Code renews its login).")
            } control: { connectControl }

            row(2, "Notifications") {
                Text("Lets your usage alerts and reset reminders reach you.")
            } control: { notificationControl }

            row(3, "Open at Login") {
                Text("Start Claude Usage whenever you log in. You can change this in Settings later.")
            } control: {
                OpenAtLoginToggle().frame(width: 150)
            }

            HStack {
                Spacer()
                Button("Done", action: done)
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            }
        }
        .padding(24)
        .frame(width: 480)
        .tint(Palette.claude)
        .task { notifications = await NotificationAccess.status() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { notifications = await NotificationAccess.status() }
        }
    }

    func row<Text: View, Control: View>(_ n: Int, _ title: String, @ViewBuilder text: () -> Text,
                                         @ViewBuilder control: () -> Control) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "\(n).circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(Palette.claude)
            VStack(alignment: .leading, spacing: 4) {
                SwiftUI.Text(title).font(.system(size: 13, weight: .semibold))
                VStack(alignment: .leading, spacing: 4, content: text)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                control().padding(.top, 2)
            }
        }
    }

    @ViewBuilder var connectControl: some View {
        if store.usage != nil, store.problem == nil {
            status("checkmark.circle.fill", .green, store.usage?.five_hour?.utilization
                .map { "Connected · session \(Int($0.rounded()))% used" } ?? "Connected")
        } else if store.loading {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Waiting for the Keychain…").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        } else if asked, let p = store.problem {
            HStack(spacing: 8) {
                status("exclamationmark.triangle.fill", Palette.ember, p.short)
                Button("Try Again", action: connect)
            }
        } else {
            Button("Connect", action: connect).buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder var notificationControl: some View {
        switch notifications {
        case .authorized?, .provisional?:
            status("checkmark.circle.fill", .green, "On")
        case .denied?:
            HStack(spacing: 8) {
                status("bell.slash", .secondary, "Off")
                Button("Open System Settings…") { NSWorkspace.shared.open(NotificationAccess.settingsURL) }
            }
        case .notDetermined?:
            Button("Allow Notifications") {
                Task {
                    await NotificationAccess.request()
                    notifications = await NotificationAccess.status()
                }
            }
        default:
            EmptyView()
        }
    }

    func status(_ icon: String, _ color: Color, _ text: String) -> some View {
        Label { Text(text) } icon: { Image(systemName: icon).foregroundStyle(color) }
            .font(.system(size: 12, weight: .medium))
    }

    func connect() {
        asked = true
        Task { await store.refresh(userInitiated: true) }
    }
}
