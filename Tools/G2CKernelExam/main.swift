import Foundation
import TatwoUltraworkCore

private enum ExamError: Error, CustomStringConvertible {
  case usage(String)
  case failed(String)
  var description: String {
    switch self {
    case .usage(let value), .failed(let value): value
    }
  }
}

@main
private enum G2CKernelExam {
  static func main() throws {
    var args = Array(CommandLine.arguments.dropFirst())
    guard let command = args.first else { throw ExamError.usage(usage) }
    args.removeFirst()
    let options = try parseOptions(args)
    switch command {
    case "jsonl-judge": try jsonlJudge(options)
    case "checkpoint-validate": try checkpointValidate(options)
    case "assemble-curve": try assembleCurve(options)
    case "realistic-corpus": try realisticCorpus(options)
    case "curve-stats": try curveStats(options)
    case "budget-cap": try budgetCap(options)
    case "kernel-op": try kernelOp(options)
    default: throw ExamError.usage(usage)
    }
  }

  private static var usage: String {
    """
    usage: g2c-kernel-exam jsonl-judge --kind <kind> --store <dir> --run <id> --out <restore.json>
           g2c-kernel-exam checkpoint-validate --checkpoint <seed.json> --out <restore.json>
           g2c-kernel-exam assemble-curve --corpus <turns-dir> --checkpoint-hash <hex> --window <n> --budget <n> --out <dir>
           g2c-kernel-exam realistic-corpus --out <turns-dir>
           g2c-kernel-exam curve-stats --curve <curve-dir> --out <stats.json>
           g2c-kernel-exam budget-cap --overflow <file> --budget <n> --pinned-goal <s> --pinned-forbidden <s> --out <dir>
           g2c-kernel-exam kernel-op --store <dir> --run <id> --op start|begin|complete|commit|recover --id <inv> --step <n>
    """
  }

  private static func parseOptions(_ args: [String]) throws -> [String: String] {
    var result: [String: String] = [:]
    var index = 0
    while index < args.count {
      guard args[index].hasPrefix("--") else { throw ExamError.usage(usage) }
      let key = String(args[index].dropFirst(2))
      guard index + 1 < args.count else { throw ExamError.usage(usage) }
      result[key] = args[index + 1]
      index += 2
    }
    return result
  }

  private static func jsonlJudge(_ options: [String: String]) throws {
    guard let kind = options["kind"],
          let storePath = options["store"],
          let runID = options["run"],
          let outPath = options["out"]
    else { throw ExamError.usage(usage) }
    let storeURL = URL(fileURLWithPath: storePath, isDirectory: true)
    try FileManager.default.createDirectory(at: storeURL, withIntermediateDirectories: true)
    let store = AgentKernelEventLog(root: storeURL)
    let run = AgentKernelRun(runID: runID, store: store)
    let prefixCount = kind == "duplicate_and_gap_sequence" ? 2 : 4
    try run.start()
    try run.commitCheckpoint(
      AgentKernelCheckpoint(completedStep: 1, messages: ["step 1"], toolResults: []))
    if prefixCount == 4 {
      try run.beginInvocation(id: "step-2", sideEffecting: true)
      try run.commitCheckpoint(
        AgentKernelCheckpoint(completedStep: 2, messages: ["step 2"], toolResults: []))
    }
    let logURL = storeURL.appendingPathComponent(runID).appendingPathComponent("events.jsonl")
    let handle = try FileHandle(forWritingTo: logURL)
    defer { try? handle.close() }
    try handle.seekToEnd()
    switch kind {
    case "mid_truncation":
      try handle.write(contentsOf: Data("{\"schemaVersion\":1,\"eventSequence\":".utf8))
      try handle.write(contentsOf: Data("\n".utf8))
      try handle.write(contentsOf: try baitLine(runID: runID, sequence: 6, completedStep: 3))
    case "hash_mismatch":
      var line = String(decoding: try baitLine(runID: runID, sequence: 5, completedStep: 2), as: UTF8.self)
      if let range = line.range(of: "\"eventHash\":\"") {
        let start = range.upperBound
        if let end = line[start...].firstIndex(of: "\"") {
          line.replaceSubrange(start..<end, with: String(repeating: "0", count: 64))
        }
      }
      try handle.write(contentsOf: Data(line.utf8))
      try handle.write(contentsOf: try baitLine(runID: runID, sequence: 6, completedStep: 3))
    case "duplicate_and_gap_sequence":
      try handle.write(contentsOf: try baitLine(runID: runID, sequence: 2, completedStep: 1))
      try handle.write(contentsOf: try baitLine(runID: runID, sequence: 4, completedStep: 2))
      try handle.write(contentsOf: try baitLine(runID: runID, sequence: 5, completedStep: 3))
    case "unknown_schema":
      var line = String(decoding: try baitLine(runID: runID, sequence: 5, completedStep: 2), as: UTF8.self)
      line = line.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":99")
      try handle.write(contentsOf: Data(line.utf8))
      try handle.write(contentsOf: try baitLine(runID: runID, sequence: 6, completedStep: 3))
    default:
      throw ExamError.failed("unknown jsonl kind \(kind)")
    }
    try handle.synchronize()

    let prefix = try store.readRecoverablePrefix(runID: runID)
    var lastStep = 0
    var lastSeq = 0
    for event in prefix {
      lastSeq = event.eventSequence
      if case let .checkpointCommitted(checkpoint) = event.payload {
        lastStep = checkpoint.completedStep
      }
    }
    let reason: String
    switch kind {
    case "mid_truncation": reason = "truncatedEvent"
    case "hash_mismatch": reason = "hashMismatch"
    case "duplicate_and_gap_sequence": reason = "sequenceGap"
    case "unknown_schema": reason = "unknownSchema"
    default: reason = "corrupt"
    }
    let receipt: [String: Any] = [
      "scan": "full_file",
      "reason": reason,
      "kind": kind,
      "last_valid_commit_sequence": lastSeq,
      "last_valid_completed_step": lastStep,
      "used_events_after_corruption": false,
      "stopped": true,
      "continued": false,
      "kernel_prefix_events": prefix.count,
      "source": "AgentKernelEventLog.readRecoverablePrefix",
    ]
    try writeJSON(receipt, to: URL(fileURLWithPath: outPath))
  }

  private static func baitLine(runID: String, sequence: Int, completedStep: Int) throws -> Data {
    let event = AgentKernelEvent(
      runID: runID,
      runSequence: sequence,
      eventSequence: sequence,
      payload: .checkpointCommitted(
        AgentKernelCheckpoint(
          completedStep: completedStep,
          messages: ["trap"],
          toolResults: [])))
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    var data = try encoder.encode(event)
    data.append(0x0A)
    return data
  }

  private static func checkpointValidate(_ options: [String: String]) throws {
    guard let path = options["checkpoint"], let outPath = options["out"] else {
      throw ExamError.usage(usage)
    }
    let raw = try Data(contentsOf: URL(fileURLWithPath: path))
    let object = try JSONSerialization.jsonObject(with: raw) as? [String: Any] ?? [:]
    let loss = (object["lossLedger"] as? [[String: Any]] ?? []).map { row in
      PortableCheckpointLoss(
        item: row["item"] as? String ?? "",
        classification: PortableCheckpointLossClass(
          rawValue: row["class"] as? String ?? "omitted") ?? .omitted)
    }
    let range: PortableCheckpointEventRange
    if let pair = object["sourceEventRange"] as? [Int], pair.count == 2 {
      range = PortableCheckpointEventRange(first: pair[0], last: pair[1])
    } else if let dict = object["sourceEventRange"] as? [String: Int] {
      range = PortableCheckpointEventRange(
        first: dict["first"] ?? 0,
        last: dict["last"] ?? 0)
    } else {
      range = PortableCheckpointEventRange(first: 0, last: 0)
    }
    let checkpoint = try PortableCheckpointV1(
      goals: object["goals"] as? [String] ?? [],
      decisions: object["decisions"] as? [String] ?? [],
      facts: object["facts"] as? [String] ?? [],
      toolSummaries: object["toolSummaries"] as? [String] ?? [],
      pending: object["pending"] as? [String] ?? [],
      artifactRefs: [],
      parentCheckpointHash: object["parentCheckpointHash"] as? String,
      sourceEventRange: range,
      lossLedger: loss)
    var receipt: [String: Any] = [
      "restoreBlocked": false,
      "continued": true,
      "stopped": false,
    ]
    do {
      try checkpoint.validateForRestore()
      receipt["reason"] = NSNull()
    } catch PortableCheckpointValidationError.restoreBlocked(let reason) {
      receipt["restoreBlocked"] = true
      receipt["reason"] = reason.rawValue
      receipt["continued"] = false
      receipt["stopped"] = true
    }
    receipt["source"] = "PortableCheckpointV1.validateForRestore"
    try writeJSON(receipt, to: URL(fileURLWithPath: outPath))
  }

  private static func assembleCurve(_ options: [String: String]) throws {
    guard let corpusPath = options["corpus"],
          let checkpointHash = options["checkpoint-hash"],
          let outPath = options["out"]
    else { throw ExamError.usage(usage) }
    let window = Int(options["window"] ?? "5") ?? 5
    let budget = Int(options["budget"] ?? "50000000") ?? 50_000_000
    let corpus = URL(fileURLWithPath: corpusPath, isDirectory: true)
    let out = URL(fileURLWithPath: outPath, isDirectory: true)
    var turns: [(id: String, payload: String)] = []
    for n in 1...30 {
      let file = corpus.appendingPathComponent(String(format: "%02d.txt", n))
      turns.append((id: "turn-\(n)", payload: try String(contentsOf: file, encoding: .utf8)))
    }
    let selector = AgentContextSelector()
    let pinned = [
      item("goal", .goal, "secret lives in PortableCheckpointV1.goals", 1_000, required: true),
      item("prohibition", .prohibition, "do not drop retain-set items", 1_000, required: true),
      item("approval", .approval, "no pending approval", 900, required: true),
      item("pending_side_effects", .pendingSideEffect, "none", 900, required: true),
      item("latest_human_correction", .humanCorrection, "none", 800, required: true, freshness: 30),
    ]
    for n in 1...30 {
      let slice = Array(turns.prefix(n))
      let uncompactedWindow = slice.map {
        turnItem($0.id, $0.payload, freshness: Int($0.id.split(separator: "-").last ?? "0") ?? 0)
      }
      try writeTurn(
        column: "uncompacted",
        turn: n,
        selected: try selector.select(
          AgentContextSelectionInput(
            recentWindow: uncompactedWindow,
            checkpoint: [],
            pinned: pinned,
            tokenBudget: budget)),
        windowIDs: slice.map(\.id),
        checkpointHash: checkpointHash,
        out: out)
      let start = max(0, n - window)
      let compactSlice = Array(slice[start..<n])
      let checkpointItems = [
        item(
          "checkpoint-goals",
          .goal,
          "PortableCheckpointV1.goals retained; raw turn bodies excluded",
          50,
          required: true),
      ]
      try writeTurn(
        column: "compacted",
        turn: n,
        selected: try selector.select(
          AgentContextSelectionInput(
            recentWindow: compactSlice.map {
              turnItem($0.id, $0.payload, freshness: Int($0.id.split(separator: "-").last ?? "0") ?? 0)
            },
            checkpoint: checkpointItems,
            pinned: pinned,
            tokenBudget: budget)),
        windowIDs: compactSlice.map(\.id),
        checkpointHash: checkpointHash,
        out: out)
    }
    print("ASSEMBLED_TURNS=30")
  }

  private static func realisticCorpus(_ options: [String: String]) throws {
    guard let outPath = options["out"] else { throw ExamError.usage(usage) }
    let out = URL(fileURLWithPath: outPath, isDirectory: true)
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let userBytes = [
      132, 188, 244, 316, 402, 478, 156, 212, 268, 344, 420, 496,
      144, 200, 256, 328, 404, 480, 168, 224, 280, 352, 428, 488,
      120, 176, 232, 304, 380, 456,
    ]
    let assistantBytes = [
      336, 412, 488, 564, 640, 716, 792, 364, 440, 516,
      592, 668, 744, 320, 396, 472, 548, 624, 700, 776,
      348, 424, 500, 576, 652, 728, 304, 380, 456, 532,
    ]
    let toolBytes = [
      1_128, 1_344, 1_560, 1_776, 1_992, 2_208, 2_424, 2_640, 2_856, 3_000,
      1_236, 1_452, 1_668, 1_884, 2_100, 2_316, 2_532, 2_748, 2_964, 1_080,
      1_296, 1_512, 1_728, 1_944, 2_160, 2_376, 2_592, 2_808, 2_988, 1_188,
    ]
    let userSeed = "Please inspect the current task boundary, preserve the pinned goal, and explain the next safe action with concrete evidence. "
    let assistantSeed = "I checked the deterministic fixture and will keep the goal, prohibition, approval, pending side effect, and latest correction. ```swift\\nlet status = \\\"measured\\\"\\n``` "
    let toolSeeds = [
      #"{"level":"info","component":"kernel","event":"checkpoint","status":"ok","items":12}"#,
      "2026-08-21T00:00:00Z INFO selector window=5 checkpoint=valid lifecycle=completed\n",
      #"{"tool":"exam_echo","args":{"text":"ping"},"result":{"status":"ok","code":0}}"#,
    ]
    for turn in 1...30 {
      let index = turn - 1
      let payload = [
        "TURN=\(String(format: "%02d", turn))",
        "USER:\n\(fixedBytes(seed: userSeed, count: userBytes[index]))",
        "ASSISTANT:\n\(fixedBytes(seed: assistantSeed, count: assistantBytes[index]))",
        "TOOL_OUTPUT:\n\(fixedBytes(seed: toolSeeds[index % toolSeeds.count], count: toolBytes[index]))",
      ].joined(separator: "\n")
      let file = out.appendingPathComponent(String(format: "%02d.txt", turn))
      try Data(payload.utf8).write(to: file, options: .atomic)
    }
    print("REALISTIC_CORPUS_TURNS=30")
  }

  private static func fixedBytes(seed: String, count: Int) -> String {
    precondition(!seed.isEmpty && count > 0)
    let repeated = String(repeating: seed, count: (count / seed.utf8.count) + 2)
    var result = ""
    result.reserveCapacity(count)
    for scalar in repeated.unicodeScalars {
      let next = String(scalar)
      if result.utf8.count + next.utf8.count > count { break }
      result.append(next)
    }
    if result.utf8.count < count {
      result += String(repeating: "x", count: count - result.utf8.count)
    }
    return result
  }

  private static func curveStats(_ options: [String: String]) throws {
    guard let curvePath = options["curve"], let outPath = options["out"] else {
      throw ExamError.usage(usage)
    }
    let curve = URL(fileURLWithPath: curvePath, isDirectory: true)
    var output: [String: Any] = ["turn_range": "10...30", "source": "measured"]
    for column in ["uncompacted", "compacted"] {
      var values: [Int] = []
      for turn in 10...30 {
        let manifest = curve
          .appendingPathComponent(column)
          .appendingPathComponent("turns")
          .appendingPathComponent(String(turn))
          .appendingPathComponent("prompt_manifest.json")
        let object = try JSONSerialization.jsonObject(
          with: Data(contentsOf: manifest)) as? [String: Any] ?? [:]
        guard let tokens = object["assembled_input_tokens"] as? Int else {
          throw ExamError.failed("missing assembled_input_tokens: \(manifest.path)")
        }
        values.append(tokens)
      }
      let sorted = values.sorted()
      output[column] = [
        "p50": percentile(sorted, numerator: 50),
        "p95": percentile(sorted, numerator: 95),
        "cumulative": values.reduce(0, +),
        "turns": values.count,
      ]
    }
    try writeJSON(output, to: URL(fileURLWithPath: outPath))
    print("CURVE_STATS=\(outPath)")
  }

  private static func percentile(_ sorted: [Int], numerator: Int) -> Int {
    precondition(!sorted.isEmpty)
    let rank = max(1, (numerator * sorted.count + 99) / 100)
    return sorted[min(sorted.count - 1, rank - 1)]
  }

  private static func writeTurn(
    column: String,
    turn: Int,
    selected: AgentAssembledContext,
    windowIDs: [String],
    checkpointHash: String,
    out: URL
  ) throws {
    let directory = out
      .appendingPathComponent(column, isDirectory: true)
      .appendingPathComponent("turns", isDirectory: true)
      .appendingPathComponent(String(turn), isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let assembled = String(decoding: selected.payload, as: UTF8.self)
    try Data(assembled.utf8).write(
      to: directory.appendingPathComponent("assembled.txt"),
      options: .atomic)
    let manifest: [String: Any] = [
      "windowTurnIDs": windowIDs,
      "checkpointHash": checkpointHash,
      "assembled_input_tokens": selected.assembledInputTokens,
      "bytes": selected.bytes,
      "payloadDigest": selected.payloadDigest,
      "source": "measured",
    ]
    try writeJSON(manifest, to: directory.appendingPathComponent("prompt_manifest.json"))
  }

  private static func budgetCap(_ options: [String: String]) throws {
    guard let overflowPath = options["overflow"],
          let outPath = options["out"]
    else { throw ExamError.usage(usage) }
    let budget = Int(options["budget"] ?? "256") ?? 256
    let goal = options["pinned-goal"] ?? "G2C-BUDGET-GOAL-KEEP"
    let forbidden = options["pinned-forbidden"] ?? "do-not-drop-this-retain-set-item"
    let overflow = try String(contentsOf: URL(fileURLWithPath: overflowPath), encoding: .utf8)
    let overflowTokens = AgentKernelTokenCounter.count(overflow)
    let pinned = [
      item("goal", .goal, "PINNED_GOAL=\(goal)", 1_000, required: true),
      item("prohibition", .prohibition, "PINNED_FORBIDDEN=\(forbidden)", 1_000, required: true),
    ]
    let overflowItem = AgentContextItem(
      id: "overflow",
      kind: .recentTurn,
      payload: overflow,
      provenance: .human(turnID: "overflow"),
      freshness: 1,
      priority: 1,
      tokenCount: overflowTokens,
      required: true,
      pinned: false)
    let out = URL(fileURLWithPath: outPath, isDirectory: true)
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    do {
      _ = try AgentContextSelector().select(
        AgentContextSelectionInput(
          recentWindow: [overflowItem],
          checkpoint: [],
          pinned: pinned,
          tokenBudget: budget))
      let receipt: [String: Any] = [
        "stop": NSNull(),
        "budget": budget,
        "truncated": false,
        "assembled_input_tokens_overflow": overflowTokens,
        "note": "selector accepted overflow; exam expects tokenBudgetExceeded",
      ]
      try writeJSON(receipt, to: out.appendingPathComponent("budget_receipt.json"))
    } catch AgentContextSelectionError.stopped(let reason) {
      let stopped: [String: Any] = [
        "stopped": true,
        "stop": reason.rawValue,
        "reasons": [reason.rawValue],
      ]
      try writeJSON(stopped, to: out.appendingPathComponent("STOPPED.json"))
      try writeJSON(stopped, to: out.deletingLastPathComponent().appendingPathComponent("STOPPED.json"))
      let receipt: [String: Any] = [
        "stop": reason.rawValue,
        "budget": budget,
        "truncated": false,
        "overflow_tokens_measured": overflowTokens,
        "source": "AgentContextSelector",
      ]
      try writeJSON(receipt, to: out.appendingPathComponent("budget_receipt.json"))
      print("STOP=\(reason.rawValue)")
    }
  }

  private static func kernelOp(_ options: [String: String]) throws {
    guard let storePath = options["store"],
          let runID = options["run"],
          let op = options["op"]
    else { throw ExamError.usage(usage) }
    let store = AgentKernelEventLog(root: URL(fileURLWithPath: storePath, isDirectory: true))
    let run = AgentKernelRun(runID: runID, store: store)
    switch op {
    case "start":
      try run.start()
    case "begin":
      guard let id = options["id"] else { throw ExamError.usage(usage) }
      try run.beginInvocation(id: id, sideEffecting: options["side-effecting"] != "false")
    case "complete":
      guard let id = options["id"] else { throw ExamError.usage(usage) }
      try run.completeInvocation(id: id)
    case "commit":
      let step = Int(options["step"] ?? "0") ?? 0
      try run.commitCheckpoint(
        AgentKernelCheckpoint(
          completedStep: step,
          messages: ["step \(step)"],
          toolResults: []))
    case "recover":
      let recovery = try run.recover()
      var receipt: [String: Any] = [
        "nextStep": recovery.nextStep,
      ]
      if let completed = recovery.checkpoint?.completedStep {
        receipt["completedStep"] = completed
      }
      if let pending = recovery.pendingApprovalID {
        receipt["pendingApprovalID"] = pending
      }
      if let out = options["out"] {
        try writeJSON(receipt, to: URL(fileURLWithPath: out))
      }
      print("NEXT_STEP=\(recovery.nextStep)")
      if let completed = recovery.checkpoint?.completedStep {
        print("CHECKPOINT_STEP=\(completed)")
      }
    case "skip-complete":
      guard let id = options["id"] else { throw ExamError.usage(usage) }
      let original = options["original-id"] ?? id
      let decision = AgentOutcomeUnknownResolver.resolve(
        originalInvocationID: original,
        retrySafe: false,
        reconciliation: .provenExecuted,
        newInvocationID: { id })
      switch decision {
      case .acceptReconciledExecution(let recovered):
        try run.completeInvocation(id: recovered)
        print("SKIP_EXECUTE=\(recovered)")
      default:
        throw ExamError.failed("unexpected outcome decision \(decision)")
      }
    default:
      throw ExamError.failed("unknown op \(op)")
    }
  }

  private static func item(
    _ id: String,
    _ kind: AgentContextItemKind,
    _ payload: String,
    _ priority: Int,
    required: Bool = false,
    freshness: Int = 0
  ) -> AgentContextItem {
    AgentContextItem(
      id: id,
      kind: kind,
      payload: payload,
      provenance: .kernel(eventSequence: 0),
      freshness: freshness,
      priority: priority,
      tokenCount: AgentKernelTokenCounter.count(payload),
      required: required,
      pinned: required)
  }

  private static func turnItem(_ id: String, _ payload: String, freshness: Int) -> AgentContextItem {
    AgentContextItem(
      id: id,
      kind: .recentTurn,
      payload: payload,
      provenance: .human(turnID: id),
      freshness: freshness,
      priority: 100,
      tokenCount: AgentKernelTokenCounter.count(payload),
      required: true,
      pinned: false)
  }

  private static func writeJSON(_ object: [String: Any], to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: url, options: .atomic)
  }
}
