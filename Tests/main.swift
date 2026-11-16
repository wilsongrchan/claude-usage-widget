import Foundation

testVersions()
testWeekBudget()
testForecast()
testGrid()
testDecoding()
testCredentials()
testNotifiedLog()
testHourlyLog()
testLoginPlan()
testReminderLog()
testDayNames()
testRestEvenly()
testSnapping()

print("\n\(checks - failures)/\(checks) checks passed")
exit(failures == 0 ? 0 : 1)
