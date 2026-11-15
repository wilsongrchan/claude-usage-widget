// The Claude Code login: read from the Keychain (or ~/.claude/.credentials.json), kept in
// memory only. Never written to disk, logs or preferences.

import Foundation

struct Credentials: Equatable {
    let token: String
    let expiresAt: Date?

    /// Within a minute of expiring (or past it). Unknown expiry counts as fine.
    func expiresSoon(now: Date) -> Bool {
        expiresAt.map { $0.timeIntervalSince(now) < 60 } ?? false
    }

    /// `{"claudeAiOauth": {"accessToken": "…", "expiresAt": <ms since 1970>}}`; expiry optional.
    static func parse(_ data: Data) -> Credentials? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        let ms = (oauth["expiresAt"] as? NSNumber)?.doubleValue
        return Credentials(token: token, expiresAt: ms.map { Date(timeIntervalSince1970: $0 / 1000) })
    }

    static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/.credentials.json")

    /// Blocks while macOS shows its Keychain prompt, so call it off the main thread.
    static func read() throws -> Credentials {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { throw UsageProblem.loginNotFound }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()

        switch p.terminationStatus {
        case 0:
            guard let c = parse(data) else { throw UsageProblem.credentialsUnreadable }
            return c
        case 44:   // errSecItemNotFound: no Keychain item, so try the file Claude Code can use instead
            if let file = try? Data(contentsOf: fileURL) {
                guard let c = parse(file) else { throw UsageProblem.credentialsUnreadable }
                return c
            }
            throw UsageProblem.loginNotFound
        default:   // the user clicked Deny, or the Keychain is locked
            throw UsageProblem.keychainDenied
        }
    }
}
