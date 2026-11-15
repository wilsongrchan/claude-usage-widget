// API model for https://api.anthropic.com/api/oauth/usage, plus the errors the widget shows.
// The endpoint is undocumented, so decoding is deliberately forgiving: every field is optional,
// a field of the wrong type reads as missing, and one malformed list entry is skipped instead
// of failing the whole response.

import Foundation

struct UsageWindow: Decodable {
    let utilization: Double?
    let resets_at: String?

    init(utilization: Double?, resets_at: String?) {
        self.utilization = utilization
        self.resets_at = resets_at
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        utilization = c.lenient(Double.self, .utilization)
        resets_at = c.lenient(String.self, .resets_at)
    }
    private enum CodingKeys: String, CodingKey { case utilization, resets_at }
}

struct LimitEntry: Decodable {
    struct Scope: Decodable {
        struct Model: Decodable {
            let display_name: String?
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                display_name = c.lenient(String.self, .display_name)
            }
            private enum CodingKeys: String, CodingKey { case display_name }
        }
        let model: Model?
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            model = c.lenient(Model.self, .model)
        }
        private enum CodingKeys: String, CodingKey { case model }
    }
    let kind: String?
    let percent: Double?
    let resets_at: String?
    let scope: Scope?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = c.lenient(String.self, .kind)
        percent = c.lenient(Double.self, .percent)
        resets_at = c.lenient(String.self, .resets_at)
        scope = c.lenient(Scope.self, .scope)
    }
    private enum CodingKeys: String, CodingKey { case kind, percent, resets_at, scope }
}

struct Breakdown: Decodable {
    struct Row: Decodable {
        let display_name: String?
        let percent: Double?
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            display_name = c.lenient(String.self, .display_name)
            percent = c.lenient(Double.self, .percent)
        }
        private enum CodingKeys: String, CodingKey { case display_name, percent }
    }
    let rows: [Row]?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rows = c.lossyArray(Row.self, .rows)
    }
    private enum CodingKeys: String, CodingKey { case rows }
}

struct Usage: Decodable {
    let five_hour: UsageWindow?
    let seven_day: UsageWindow?
    let limits: [LimitEntry]?
    let seven_day_breakdown: Breakdown?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        five_hour = c.lenient(UsageWindow.self, .five_hour)
        seven_day = c.lenient(UsageWindow.self, .seven_day)
        limits = c.lossyArray(LimitEntry.self, .limits)
        seven_day_breakdown = c.lenient(Breakdown.self, .seven_day_breakdown)
    }
    private enum CodingKeys: String, CodingKey { case five_hour, seven_day, limits, seven_day_breakdown }
}

/// Decodes nothing; used to step over a list entry that failed to decode.
private struct Skip: Decodable { init(from decoder: Decoder) throws {} }

extension KeyedDecodingContainer {
    /// The value, or nil if it's missing, null or the wrong type.
    func lenient<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        (try? decodeIfPresent(type, forKey: key)) ?? nil
    }

    /// Every entry that decodes; bad entries are skipped. Nil if the list itself is missing.
    func lossyArray<T: Decodable>(_ type: T.Type, _ key: Key) -> [T]? {
        guard var list = try? nestedUnkeyedContainer(forKey: key) else { return nil }
        var out: [T] = []
        while !list.isAtEnd {
            if let v = try? list.decode(T.self) {
                out.append(v)
            } else if (try? list.decode(Skip.self)) == nil {
                break   // couldn't even step over it; stop rather than loop forever
            }
        }
        return out
    }
}

func parseDate(_ s: String?) -> Date? {
    guard let s else { return nil }
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: s) { return d }
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: s)
}

/// Minute-resolution key for a reset time (the API's fractional seconds jitter between calls).
func windowKey(_ d: Date) -> Int { Int((d.timeIntervalSince1970 / 60).rounded()) }

// MARK: - Problems shown to the user

/// Something stopping a reading. Each has a short form (status lines, menu bar tooltip) and a
/// long form (the large widget and the popover).
enum UsageProblem: Error, Equatable {
    case loginExpired
    case loginNotFound
    case keychainDenied
    case credentialsUnreadable
    case unavailable(status: Int)
    case badResponse

    var short: String {
        switch self {
        case .loginExpired: "Login expired"
        case .loginNotFound: "Claude Code not found"
        case .keychainDenied: "Keychain access denied"
        case .credentialsUnreadable: "Can't read Claude Code login"
        case .unavailable, .badResponse: "Usage unavailable"
        }
    }

    var long: String {
        switch self {
        case .loginExpired: "Use Claude Code once to refresh your login."
        case .loginNotFound: "Install Claude Code and log in."
        case .keychainDenied: "Allow access when macOS asks, then press Refresh."
        case .credentialsUnreadable: "Log out of Claude Code and log in again."
        case .unavailable(let status): "Anthropic returned HTTP \(status)."
        case .badResponse: "Anthropic sent a reply the app couldn't read."
        }
    }
}

/// Rate limited: back off, keep showing the last reading.
struct RateLimited: Error { let retryAfter: TimeInterval? }
