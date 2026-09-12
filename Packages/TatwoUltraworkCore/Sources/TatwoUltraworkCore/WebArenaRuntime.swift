import Foundation

public enum TatwoWebArenaRuntime {
  public static func defaultRunID(now: Date = Date()) -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyyMMdd"
    return "\(formatter.string(from: now))-web-arena-v1"
  }

  public static func parseOlderThanDays(_ raw: String) -> Int {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let digits = trimmed.replacingOccurrences(of: "[^0-9]", with: "", options: .regularExpression)
    return max(1, Int(digits) ?? 14)
  }
}
