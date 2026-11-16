// Update check: once a day, ask GitHub for the latest release and say so if it's newer.
// Nothing is downloaded or installed; the user gets a link to the release page.

import AppKit
import SwiftUI

enum AppInfo {
    /// From Info.plist (set in build.sh), so the User-Agent and update check always match the build.
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    static let repo = "wilsongrchan/claude-usage-widget"
    static let releasesURL = URL(string: "https://github.com/\(repo)/releases/latest")!
}

@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()
    static let enabledKey = "checkUpdates"
    private static let lastCheckKey = "lastUpdateCheck"
    private static let skippedKey = "skippedUpdateVersion"
    private static let interval: TimeInterval = 24 * 3600

    @Published private(set) var latest: String?
    @Published private(set) var releaseURL = AppInfo.releasesURL
    @Published private(set) var checking = false
    @Published private(set) var failed = false
    private var timer: Timer?

    var enabled: Bool { UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true }
    /// A newer release exists (whether or not the user skipped it).
    var newer: Bool { latest.map { Self.isNewer($0, than: AppInfo.version) } == true }
    /// Show the "!" on the wordmark: newer, notifications on, and not skipped.
    var updateAvailable: Bool {
        enabled && newer && latest != UserDefaults.standard.string(forKey: Self.skippedKey)
    }

    func start() {
        // Hourly look at whether a day has passed: a 24h timer would drift across sleep.
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            Task { @MainActor in UpdateChecker.shared.checkIfDue() }
        }
        checkIfDue()
    }

    func checkIfDue() {
        guard enabled else { return }
        let last = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date ?? .distantPast
        if Date().timeIntervalSince(last) >= Self.interval || latest == nil { check() }
    }

    func check() {
        guard !checking else { return }
        checking = true
        Task {
            let result = await Self.fetchLatest()
            checking = false
            if let (tag, url) = result {
                latest = tag
                releaseURL = url
                failed = false
                UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
            } else {
                failed = true
            }
        }
    }

    @objc func openRelease() { NSWorkspace.shared.open(releaseURL) }

    /// Hide the "!" until a later version comes out.
    @objc func skipVersion() {
        objectWillChange.send()
        UserDefaults.standard.set(latest, forKey: Self.skippedKey)
    }

    /// The "!" was clicked: download or skip.
    func showMenu() {
        let menu = NSMenu()
        let title = NSMenuItem(title: "Version \(latest ?? "") is available (you have \(AppInfo.version))",
                               action: nil, keyEquivalent: "")
        title.isEnabled = false
        let get = NSMenuItem(title: "Download Update", action: #selector(openRelease), keyEquivalent: "")
        get.target = self
        get.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: nil)
        let skip = NSMenuItem(title: "Skip This Version", action: #selector(skipVersion), keyEquivalent: "")
        skip.target = self
        skip.image = NSImage(systemSymbolName: "forward", accessibilityDescription: nil)
        menu.items = [title, .separator(), get, skip]
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    /// Latest published release (GitHub's /latest skips drafts and pre-releases).
    nonisolated static func fetchLatest() async -> (String, URL)? {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(AppInfo.repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("claude-usage-widget/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        let config = URLSessionConfiguration.ephemeral   // fresh each time, as with the usage request
        config.timeoutIntervalForRequest = 20
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        guard let (data, resp) = try? await session.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String else { return nil }
        let url = (json["html_url"] as? String).flatMap(URL.init(string:)) ?? AppInfo.releasesURL
        return (tag.hasPrefix("v") ? String(tag.dropFirst()) : tag, url)
    }

    nonisolated static func isNewer(_ a: String, than b: String) -> Bool { isNewerVersion(a, than: b) }
}

/// Orange "!" on the wordmark's top-right when a new version is out; click to download or skip.
struct UpdateDot: View {
    @ObservedObject var updates = UpdateChecker.shared

    var body: some View {
        if updates.updateAvailable {
            Button { updates.showMenu() } label: {
                Image(systemName: "exclamationmark")   // a badge glyph, not text
                    .font(.system(size: 6, weight: .black))
                    .foregroundStyle(.white)
                    .frame(width: 9, height: 9)
                    .background(Circle().fill(Palette.claude))
                    .frame(width: 20, height: 20)       // small dot, generous click target
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Version \(updates.latest ?? "") is available")
            .accessibilityLabel("Update available: version \(updates.latest ?? "")")
            .transition(.scale.combined(with: .opacity))
        }
    }
}

/// About tab: current version, update status and the daily-check switch.
struct VersionSection: View {
    @ObservedObject var updates = UpdateChecker.shared
    @AppStorage(UpdateChecker.enabledKey) var checkUpdates = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Label("Version \(AppInfo.version)", systemImage: "app.badge")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.claude)
                Spacer(minLength: 4)
                if updates.newer {
                    PillButton(title: "Download \(updates.latest ?? "")",
                               prominent: true) { updates.openRelease() }
                } else if updates.checking {
                    ProgressView().controlSize(.mini)
                } else {
                    PillButton(title: "Check now") { updates.check() }
                }
            }
            Text(statusText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    var statusText: String {
        if updates.newer {
            return "Version \(updates.latest ?? "") is out. Quit this app, then replace it with the new one from GitHub."
        }
        if updates.checking { return "Checking GitHub…" }
        if updates.failed { return "Couldn't reach GitHub. Try again later." }
        if let l = updates.latest, !UpdateChecker.isNewer(l, than: AppInfo.version) { return "You're up to date." }
        return checkUpdates ? "Checks GitHub once a day." : "Update notifications are off (Alerts)."
    }
}
