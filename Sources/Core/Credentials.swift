// The Claude Code login: read from the Keychain (or ~/.claude/.credentials.json), kept in
// memory only. Never written to disk, logs or preferences.

import Foundation

struct Credentials: Equatable, Sendable {
    let token: String
    let expiresAt: Date?

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

    static let service = "Claude Code-credentials"

    /// Reads the secret. With plain "Allow" this shows the Keychain prompt, so it's only called
    /// when `LoginPlan` says so. Blocks while the prompt is up: call it off the main thread.
    static func read() throws -> Credentials {
        let (status, data) = security(["find-generic-password", "-s", service, "-w"])
        switch status {
        case 0:
            guard let c = parse(data) else { throw UsageProblem.credentialsUnreadable }
            return c
        case 44:   // errSecItemNotFound: no Keychain item, so try the file Claude Code can use instead
            if let file = try? Data(contentsOf: fileURL) {
                guard let c = parse(file) else { throw UsageProblem.credentialsUnreadable }
                return c
            }
            throw UsageProblem.loginNotFound
        case -1: throw UsageProblem.loginNotFound   // couldn't run /usr/bin/security
        default:   // the user clicked Deny, or the Keychain is locked
            throw UsageProblem.keychainDenied
        }
    }

    /// Identifies the stored login without reading the secret: the Keychain item's creation and
    /// modification dates (reading attributes never prompts, even with plain "Allow"; tested on
    /// macOS 26 with an item that trusts no app), or the credentials file's modification date.
    /// It changes whenever Claude Code writes a new login. nil if it can't be read.
    static func stamp() -> String? {
        let (status, data) = security(["find-generic-password", "-s", service])
        switch status {
        case 0: return parseStamp(String(decoding: data, as: UTF8.self))
        case 44:
            let date = (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.modificationDate] as? Date
            return date.map { "file \($0.timeIntervalSince1970)" }
        default: return nil
        }
    }

    /// The `cdat` and `mdat` lines of `security find-generic-password` output (no `-w`).
    static func parseStamp(_ output: String) -> String? {
        let lines = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let dates = lines.filter { $0.hasPrefix("\"cdat\"") || $0.hasPrefix("\"mdat\"") }
        return dates.isEmpty ? nil : dates.joined(separator: " ")
    }

    private static func security(_ args: [String]) -> (Int32, Data) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return (-1, Data()) }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, data)
    }
}

/// What a refresh does about the login, decided before touching the network.
/// Reading the secret can show a Keychain prompt (plain "Allow"), so it happens only when there's
/// no login in memory, the user pressed Refresh, or Claude Code has written a new login since.
enum LoginPlan: Equatable {
    /// The login in memory is still good: no Keychain access at all.
    case useCached
    /// Read the secret (may prompt).
    case readSecret
    /// The login in memory has expired or was rejected and Claude Code hasn't written a new one:
    /// show "Login expired" without asking the Keychain or calling the API.
    case expired

    /// - cached: the login in memory; cachedStamp: `Credentials.stamp()` when it was read.
    /// - rejected: the API turned that login down.
    /// - currentStamp: called only when needed (expired or rejected login).
    static func decide(cached: Credentials?, cachedStamp: String?, rejected: Bool, userInitiated: Bool,
                       now: Date, currentStamp: () -> String?) -> LoginPlan {
        guard let cached, !userInitiated else { return .readSecret }
        let expired = rejected || (cached.expiresAt.map { $0 <= now } ?? false)
        guard expired else { return .useCached }
        if let s = currentStamp(), s != cachedStamp { return .readSecret }
        return .expired
    }
}
