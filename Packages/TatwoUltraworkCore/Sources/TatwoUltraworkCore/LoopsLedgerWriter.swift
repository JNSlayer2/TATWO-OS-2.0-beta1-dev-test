import Foundation

public enum TatwoLoopsLedgerWriter {
  public static func makeEntry(
    contractID: String,
    goalID: String,
    identity: IdentityKind,
    modelID: String,
    subtask: String,
    status: TatwoDispatchStatus,
    roundIndex: Int
  ) -> TatwoDispatchLedgerEntry {
    let timestamp = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
    let ledgerStatus = ledgerStatus(for: status)
    let metadata = [
      "contractID=\(contractID)",
      "goalID=\(goalID)",
      "identity=\(identity.rawValue)",
      "roundIndex=\(roundIndex)",
    ].joined(separator: " ")

    return TatwoDispatchLedgerEntry(
      id: "loops-\(contractID)-\(goalID)-\(identity.rawValue)-round-\(roundIndex)",
      label: subtask,
      model: modelID,
      status: ledgerStatus,
      startedAt: timestamp,
      endedAt: ledgerStatus.isActive ? nil : timestamp,
      note: metadata)
  }

  public static func encodeJSONL(_ entry: TatwoDispatchLedgerEntry) -> String {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]

    do {
      return String(decoding: try encoder.encode(entry), as: UTF8.self)
    } catch {
      preconditionFailure("TatwoDispatchLedgerEntry encoding failed: \(error)")
    }
  }

  private static func ledgerStatus(
    for status: TatwoDispatchStatus
  ) -> TatwoDispatchLedgerStatus {
    switch status {
    case .queued:
      return .dispatched
    case .running:
      return .running
    case .completed:
      return .done
    case .verified:
      // Origin acceptance (design「已驗收」) stays distinct from execution `.done`.
      return .verified
    case .failed:
      return .failed
    }
  }
}
