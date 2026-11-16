// Minimal test harness: no XCTest (not reliably installed with the Command Line Tools alone).
// `./build.sh test` compiles Sources/Core + Tests into one binary and runs it.

import Foundation

var checks = 0
var failures = 0

func expect(_ condition: Bool, _ message: @autoclosure () -> String = "",
            file: String = #fileID, line: Int = #line) {
    checks += 1
    if !condition {
        failures += 1
        print("  FAIL \(file):\(line) \(message())")
    }
}

func expectEqual<T: Equatable>(_ a: T, _ b: T, _ message: String = "",
                               file: String = #fileID, line: Int = #line) {
    expect(a == b, "\(a) != \(b) \(message)", file: file, line: line)
}

func expectClose(_ a: Double?, _ b: Double, tolerance: Double = 1e-6, _ message: String = "",
                 file: String = #fileID, line: Int = #line) {
    expect(a.map { abs($0 - b) <= tolerance } ?? false, "\(a.map { "\($0)" } ?? "nil") !≈ \(b) \(message)",
           file: file, line: line)
}

func suite(_ name: String, _ body: () -> Void) {
    let before = failures
    body()
    print(failures == before ? "ok   \(name)" : "FAIL \(name)")
}

/// A throwaway preferences domain, deleted afterwards.
func withDefaults(_ body: (UserDefaults) -> Void) {
    let name = "claude-usage-tests-\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    body(d)
    d.removePersistentDomain(forName: name)
}

/// Fixed calendar for date maths: Gregorian, UTC.
let utc: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}()

func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
    utc.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
}
