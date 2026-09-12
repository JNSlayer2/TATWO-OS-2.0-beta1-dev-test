import Foundation
import TatwoUltraworkCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private enum DriverError: Error, CustomStringConvertible {
  case usage(String), invalidTask(String), transport(String), tool(String)
  var description: String {
    switch self {
    case .usage(let value), .invalidTask(let value), .transport(let value), .tool(let value): value
    }
  }
}

private struct Step {
  let number: Int
  let instruction: String
}

private struct TransportReply: Decodable {
  let actual: String?
  let effort: String?
  let message: String?
}

@main
private enum AgentKernelDriver {
  static func main() async {
    do { try await run() }
    catch {
      FileHandle.standardError.write(Data("agent-kernel-driver: \(error)\n".utf8))
      exit(1)
    }
  }

  private static func run() async throws {
    var args = Array(CommandLine.arguments.dropFirst())
    guard let command = args.first else { throw DriverError.usage(usage) }
    args.removeFirst()
    let options = try parseOptions(args)
    guard let storePath = options["store"] else { throw DriverError.usage("missing --store\n\(usage)") }
    let transport = options["transport"] ?? "codex"
    guard ["codex", "claude", "grok"].contains(transport) else { throw DriverError.usage("unsupported transport: \(transport)") }
    let checkpointOnly = options["checkpoint-only"] == "true"
    guard !checkpointOnly || command == "resume" else {
      throw DriverError.usage("--checkpoint-only is valid only with resume")
    }
    let contextMode = options["context"] ?? "uncompacted"
    guard ["uncompacted", "compacted"].contains(contextMode) else {
      throw DriverError.usage("unsupported context mode: \(contextMode)")
    }
    let contextBudget = Int(options["context-budget"] ?? "4096") ?? 0
    guard contextBudget > 0 else {
      throw DriverError.usage("--context-budget must be positive")
    }

    let storeURL = URL(fileURLWithPath: storePath, isDirectory: true)
    let store = AgentKernelEventLog(root: storeURL)
    let runID: String
    let taskURL: URL
    let isResume: Bool
    switch command {
    case "run":
      guard let taskPath = options["task"] else { throw DriverError.usage("missing --task\n\(usage)") }
      taskURL = URL(fileURLWithPath: taskPath, isDirectory: true)
      runID = options["run"] ?? UUID().uuidString.lowercased()
      isResume = false
    case "resume":
      guard let value = options["run"] else { throw DriverError.usage("missing --run\n\(usage)") }
      runID = value
      let metadata = storeURL.appendingPathComponent(runID).appendingPathComponent("driver.json")
      let object = try JSONSerialization.jsonObject(with: Data(contentsOf: metadata)) as? [String: String]
      guard let path = object?["task"] else { throw DriverError.invalidTask("run metadata missing task path") }
      taskURL = URL(fileURLWithPath: path, isDirectory: true)
      isResume = true
    default: throw DriverError.usage(usage)
    }

    let taskFile = taskURL.appendingPathComponent("task.md")
    let steps = try parseTask(String(contentsOf: taskFile, encoding: .utf8))
    let run = AgentKernelRun(runID: runID, store: store)
    if isResume {
      let metadata = try loadMetadata(store: storeURL, runID: runID)
      if let pidText = metadata["pid"], let pid = Int32(pidText),
         pid != getpid(), kill(pid, 0) == 0 {
        throw AgentKernelStoreError.leaseHeld
      }
      try? store.releaseLease(runID: runID)
    }
    try store.acquireLease(runID: runID)
    defer { try? store.releaseLease(runID: runID) }

    if !isResume {
      try run.start()
      try saveMetadata(store: storeURL, runID: runID, task: taskURL.path, transport: transport)
    } else {
      let events = try store.read(runID: runID)
      let previous = events.reversed().compactMap { event -> String? in
        if case .turnAttested(let value) = event.payload { return value.actual }
        return nil
      }.first
      if let previous, previous != transport {
        _ = try run.changeTransport(to: transport)
      }
      try saveMetadata(store: storeURL, runID: runID, task: taskURL.path, transport: transport)
    }

    let recovery = try run.recover()
    print("RUN_ID=\(runID)")
    print("NEXT_STEP=\(recovery.nextStep)")
    fflush(stdout)

    let portableCheckpoint: PortableCheckpointV1? = checkpointOnly
      ? try loadPortableCheckpoint(store: storeURL, runID: runID, artifactRoot: taskURL)
      : nil
    if checkpointOnly {
      print("CHECKPOINT_ONLY=true")
      print("CONTINUATION=null")
    }
    var messages = checkpointOnly ? [] : (recovery.checkpoint?.messages ?? [])
    var results = checkpointOnly ? [] : (recovery.checkpoint?.toolResults ?? [])
    for step in steps where step.number >= recovery.nextStep {
      let invocationID = "step-\(step.number)"
      try run.beginInvocation(id: invocationID, sideEffecting: true)
      let context: DriverPromptContext
      do {
        context = try makePromptContext(
          mode: contextMode,
          budget: contextBudget,
          task: taskFile.path,
          runID: runID,
          step: step,
          transport: transport,
          messages: messages,
          results: results,
          portableCheckpoint: portableCheckpoint)
      } catch AgentContextSelectionError.stopped(let reason) {
        try run.stop(reason: reason)
        throw DriverError.transport("STOPPED: \(reason.rawValue)")
      }
      let runDirectory = storeURL.appendingPathComponent(
        runID,
        isDirectory: true)
      _ = try AgentPromptManifestWriter.write(
        context.manifest,
        turnID: invocationID,
        runDirectory: runDirectory)
      let reply = try invokeTransport(
        transport,
        prompt: context.prompt)
      let actual = reply.actual ?? transport
      let effort = reply.effort ?? "exam"
      guard actual == transport else { throw DriverError.transport("transport attestation mismatch: requested \(transport), actual \(actual)") }
      let result = try execute(step: step, taskURL: taskURL, callID: invocationID)
      try run.completeInvocation(id: invocationID)
      messages.append(reply.message ?? "step \(step.number) completed via \(transport)")
      results.append(result)
      try run.attestTurn(requested: transport, actual: actual, effort: effort)
      try run.commitCheckpoint(AgentKernelCheckpoint(completedStep: step.number, messages: messages, toolResults: results))
      try savePortableCheckpoint(
        store: storeURL,
        runID: runID,
        completedStep: step.number,
        messages: messages,
        results: results)
      print("CHECKPOINT_STEP=\(step.number)")
      fflush(stdout)
      if ProcessInfo.processInfo.environment["AGENT_KERNEL_PAUSE_AFTER_STEP"] == String(step.number) {
        while true { sleep(1) }
      }
    }
    print("COMPLETED_RUN_ID=\(runID)")
  }

  private static var usage: String { "usage: agent-kernel-driver run --task <dir> --store <dir> --transport codex|claude|grok [--run <id>] [--context uncompacted|compacted] [--context-budget <tokens>]\n       agent-kernel-driver resume --run <id> --store <dir> [--transport codex|claude|grok] [--checkpoint-only] [--context uncompacted|compacted] [--context-budget <tokens>]" }

  private static func parseOptions(_ args: [String]) throws -> [String: String] {
    var result: [String: String] = [:]
    var index = 0
    while index < args.count {
      guard args[index].hasPrefix("--") else { throw DriverError.usage(usage) }
      let key = String(args[index].dropFirst(2))
      if key == "checkpoint-only" {
        result[key] = "true"
        index += 1
      } else {
        guard index + 1 < args.count else { throw DriverError.usage(usage) }
        result[key] = args[index + 1]
        index += 2
      }
    }
    return result
  }

  private static func parseTask(_ text: String) throws -> [Step] {
    var steps: [Step] = []
    for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
      let line = raw.trimmingCharacters(in: .whitespaces)
      guard line.lowercased().hasPrefix("step "), let divider = line.range(of: "::") else { continue }
      let head = line[..<divider.lowerBound].split(separator: " ")
      guard head.count == 2, let number = Int(head[1]), number == steps.count + 1 else {
        throw DriverError.invalidTask("steps must be contiguous and use: STEP <n> :: <tool instruction>")
      }
      steps.append(Step(number: number, instruction: String(line[divider.upperBound...]).trimmingCharacters(in: .whitespaces)))
    }
    guard !steps.isEmpty else { throw DriverError.invalidTask("task.md contains no STEP lines") }
    return steps
  }

  // 主導驗收機械修正：模板佔位符 "TRANSPORT" 未插值，真模型照抄字面
  // 導致 attestation 必炸（sol sandbox 只能跑假樁所以沒發現）。
  private static func prompt(
    task: String, runID: String, step: Step, transport: String
  ) -> String {
    """
    Agent kernel exam. Return one JSON object only: {"actual":"\(transport)","effort":"exam","message":"short result"}.
    Run: \(runID). Task: \(task). Step \(step.number): \(step.instruction)
    Do not execute tools; the kernel's allowlisted executor will execute the instruction.
    """
  }

  private struct DriverPromptContext {
    let prompt: String
    let manifest: AgentPromptManifestV1
  }

  private static func makePromptContext(
    mode: String,
    budget: Int,
    task: String,
    runID: String,
    step: Step,
    transport: String,
    messages: [String],
    results: [TatwoNativeToolResultRecord],
    portableCheckpoint: PortableCheckpointV1?
  ) throws -> DriverPromptContext {
    if let portableCheckpoint {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      let checkpointData = try encoder.encode(portableCheckpoint)
      let value = """
      Agent kernel checkpoint-only restore. continuation=null. Do not infer or request prior messages, tool results, or vendor session state.
      PortableCheckpointV1:
      \(String(decoding: checkpointData, as: UTF8.self))
      Current step \(step.number): \(step.instruction)
      Return one JSON object only: {"actual":"\(transport)","effort":"exam","message":"short result"}.
      """
      return DriverPromptContext(
        prompt: value,
        manifest: AgentPromptManifestV1(
          windowTurnIDs: ["step-\(step.number)"],
          checkpointHash: portableCheckpoint.contentHash,
          assembledInputTokens: AgentKernelTokenCounter.count(value),
          bytes: Data(value.utf8).count,
          payloadDigest: AgentKernelDigest.sha256Hex(Data(value.utf8))))
    }
    if mode == "uncompacted" {
      let value = prompt(
        task: task,
        runID: runID,
        step: step,
        transport: transport)
      let data = Data(value.utf8)
      return DriverPromptContext(
        prompt: value,
        manifest: AgentPromptManifestV1(
          windowTurnIDs: messages.indices.map { "turn-\($0 + 1)" }
            + ["step-\(step.number)"],
          checkpointHash: checkpointHash(messages: messages, results: results),
          assembledInputTokens: AgentKernelTokenCounter.count(value),
          bytes: data.count,
          payloadDigest: AgentKernelDigest.sha256Hex(data)))
    }

    let checkpointHash = checkpointHash(messages: messages, results: results)
    let pinned = [
      contextItem(
        id: "protocol",
        kind: .prohibition,
        payload: "Return one JSON object only with actual=\(transport), effort=exam, and a short message. Do not execute tools.",
        priority: 1_000,
        required: true),
      contextItem(
        id: "goal",
        kind: .goal,
        payload: "Complete the current allowlisted agent-kernel task step.",
        priority: 1_000,
        required: true),
    ]
    let checkpoint = messages.enumerated().map {
      contextItem(
        id: "checkpoint-message-\($0.offset + 1)",
        kind: .toolSummary,
        payload: $0.element,
        freshness: $0.offset + 1,
        priority: 20,
        provenance: .checkpoint(
          hash: checkpointHash,
          field: "toolSummaries"))
    } + results.enumerated().map {
      contextItem(
        id: "checkpoint-result-\($0.offset + 1)",
        kind: .toolSummary,
        payload: $0.element.output,
        freshness: $0.offset + 1,
        priority: 20,
        provenance: .checkpoint(
          hash: checkpointHash,
          field: "toolSummaries"))
    }
    let recent = [
      contextItem(
        id: "step-\(step.number)",
        kind: .recentTurn,
        payload: "Run \(runID). Task \(task). Step \(step.number): \(step.instruction)",
        freshness: step.number,
        priority: 100,
        required: true),
    ]
    let selected = try AgentContextSelector().select(
      AgentContextSelectionInput(
        recentWindow: recent,
        checkpoint: checkpoint,
        pinned: pinned,
        tokenBudget: budget))
    let value = String(decoding: selected.payload, as: UTF8.self)
    return DriverPromptContext(
      prompt: value,
      manifest: AgentPromptManifestV1(
        windowTurnIDs: recent.map(\.id),
        checkpointHash: checkpointHash,
        assembledInputTokens: selected.assembledInputTokens,
        bytes: selected.bytes,
        payloadDigest: selected.payloadDigest))
  }

  private static func contextItem(
    id: String,
    kind: AgentContextItemKind,
    payload: String,
    freshness: Int = 0,
    priority: Int,
    required: Bool = false,
    provenance: AgentContextProvenance = .kernel(eventSequence: 0)
  ) -> AgentContextItem {
    AgentContextItem(
      id: id,
      kind: kind,
      payload: payload,
      provenance: provenance,
      freshness: freshness,
      priority: priority,
      tokenCount: AgentKernelTokenCounter.count(payload),
      required: required,
      pinned: required)
  }

  private static func checkpointHash(
    messages: [String],
    results: [TatwoNativeToolResultRecord]
  ) -> String {
    struct Material: Encodable {
      let messages: [String]
      let results: [TatwoNativeToolResultRecord]
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try! encoder.encode(
      Material(messages: messages, results: results))
    return AgentKernelDigest.sha256Hex(data)
  }

  private static func invokeTransport(_ transport: String, prompt: String) throws -> TransportReply {
    let env = ProcessInfo.processInfo.environment
    let variable = [
      "codex": "AGENT_KERNEL_CODEX_BIN",
      "claude": "AGENT_KERNEL_CLAUDE_BIN",
      "grok": "AGENT_KERNEL_GROK_BIN",
    ][transport]!
    let override = env[variable]
    let executable = override ?? (
      transport == "grok"
        ? "\(NSHomeDirectory())/.codex/bin/grok-isolated"
        : findExecutable(transport))
    guard let executable else { throw DriverError.transport("BLOCKED: \(transport) executable unavailable") }
    guard FileManager.default.isExecutableFile(atPath: executable) else {
      throw DriverError.transport("BLOCKED: \(transport) executable unavailable at \(executable)")
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    switch transport {
    case "codex":
      process.arguments = ["exec", "--skip-git-repo-check", prompt]
    case "claude":
      process.arguments = ["-p", prompt, "--output-format", "json"]
    case "grok":
      process.arguments = ["-p", prompt, "--output-format", "streaming-json"]
    default:
      process.arguments = ["-p", prompt]
    }
    let output = Pipe(), error = Pipe()
    process.standardOutput = output; process.standardError = error; process.standardInput = FileHandle.nullDevice
    try process.run()
    let stdoutBox = LockedData()
    let stderrBox = LockedData()
    let readers = DispatchGroup()
    readers.enter()
    DispatchQueue.global(qos: .utility).async {
      stdoutBox.set(output.fileHandleForReading.readDataToEndOfFile())
      readers.leave()
    }
    readers.enter()
    DispatchQueue.global(qos: .utility).async {
      stderrBox.set(error.fileHandleForReading.readDataToEndOfFile())
      readers.leave()
    }
    let timeoutSeconds = Double(env["AGENT_KERNEL_TRANSPORT_TIMEOUT_SECONDS"] ?? "120") ?? 120
    let deadline = Date().addingTimeInterval(max(1, timeoutSeconds))
    while process.isRunning && Date() < deadline {
      Thread.sleep(forTimeInterval: 0.05)
    }
    if process.isRunning {
      process.terminate()
      process.waitUntilExit()
      readers.wait()
      throw DriverError.transport(
        "\(transport) timed out after \(Int(max(1, timeoutSeconds)))s")
    }
    process.waitUntilExit()
    readers.wait()
    let stdout = String(decoding: stdoutBox.get(), as: UTF8.self)
    let stderr = String(decoding: stderrBox.get(), as: UTF8.self)
    guard process.terminationStatus == 0 else { throw DriverError.transport("\(transport) failed (\(process.terminationStatus)): \(stderr)") }
    for candidate in transportReplyCandidates(stdout, streamingJSON: transport == "grok") {
      if let decoded = try? JSONDecoder().decode(TransportReply.self, from: candidate) {
        return decoded
      }
    }
    throw DriverError.transport(
      "\(transport) returned no parseable transport attestation")
  }

  private static func transportReplyCandidates(
    _ stdout: String,
    streamingJSON: Bool
  ) -> [Data] {
    var candidates: [Data] = []
    if streamingJSON {
      // grok streaming-json 逐 token 送 {"type":"text","data":"…"}；回覆 JSON 散在
      // 多個 text 事件，必須先串接全部 data 再抽取。
      var combinedText = ""
      for line in stdout.split(separator: "\n") {
        guard let envelope = try? JSONSerialization.jsonObject(
          with: Data(line.utf8)) as? [String: Any] else { continue }
        if envelope["type"] as? String == "text", let data = envelope["data"] as? String {
          combinedText += data
        }
        for key in ["result", "text", "content", "message"] {
          if let value = envelope[key] as? String {
            candidates.append(Data(value.utf8))
          }
        }
      }
      if let start = combinedText.firstIndex(of: "{"), let end = combinedText.lastIndex(of: "}") {
        candidates.append(Data(combinedText[start...end].utf8))
      }
    }
    if let envelope = try? JSONSerialization.jsonObject(
      with: Data(stdout.utf8)) as? [String: Any] {
      for key in ["result", "text", "content", "message"] {
        if let value = envelope[key] as? String {
          candidates.append(Data(value.utf8))
        }
      }
    }
    if let start = stdout.firstIndex(of: "{"), let end = stdout.lastIndex(of: "}") {
      candidates.append(Data(stdout[start...end].utf8))
    }
    return candidates
  }

  private final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Data()

    func set(_ next: Data) {
      lock.lock()
      value = next
      lock.unlock()
    }

    func get() -> Data {
      lock.lock()
      defer { lock.unlock() }
      return value
    }
  }

  private static func savePortableCheckpoint(
    store: URL,
    runID: String,
    completedStep: Int,
    messages: [String],
    results: [TatwoNativeToolResultRecord]
  ) throws {
    let checkpoint = try PortableCheckpointV1(
      goals: ["complete remaining task steps"],
      decisions: ["resume only at checkpoint boundary"],
      facts: messages,
      toolSummaries: results.map(\.output),
      pending: ["continue from step \(completedStep + 1)"],
      artifactRefs: [],
      parentCheckpointHash: nil,
      sourceEventRange: .init(first: 1, last: completedStep),
      lossLedger: [])
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(checkpoint).write(
      to: store.appendingPathComponent(runID)
        .appendingPathComponent("portable-checkpoint-v1.json"),
      options: .atomic)
  }

  private static func loadPortableCheckpoint(
    store: URL,
    runID: String,
    artifactRoot: URL
  ) throws -> PortableCheckpointV1 {
    let data = try Data(contentsOf: store.appendingPathComponent(runID)
      .appendingPathComponent("portable-checkpoint-v1.json"))
    let checkpoint = try PortableCheckpointV1.decodeAndValidate(data)
    try checkpoint.validateForRestore(artifactRoot: artifactRoot)
    return checkpoint
  }

  private static func findExecutable(_ name: String) -> String? {
    for directory in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
      let path = URL(fileURLWithPath: String(directory)).appendingPathComponent(name).path
      if FileManager.default.isExecutableFile(atPath: path) { return path }
    }
    return nil
  }

  private static func execute(step: Step, taskURL: URL, callID: String) throws -> TatwoNativeToolResultRecord {
    let parts = step.instruction.split(separator: " ", maxSplits: 2).map(String.init)
    guard parts.count >= 2 else { throw DriverError.tool("invalid tool instruction at step \(step.number)") }
    let verb = parts[0], relative = parts[1]
    guard !relative.hasPrefix("/"), !relative.split(separator: "/").contains("..") else { throw DriverError.tool("path escapes task directory") }
    let target = taskURL.appendingPathComponent(relative)
    switch verb {
    case "append":
      guard parts.count == 3 else { throw DriverError.tool("append requires path and text") }
      try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
      let data = Data((parts[2] + "\n").utf8)
      if !FileManager.default.fileExists(atPath: target.path) { FileManager.default.createFile(atPath: target.path, contents: nil) }
      let handle = try FileHandle(forWritingTo: target); defer { try? handle.close() }
      try handle.seekToEnd(); try handle.write(contentsOf: data); try handle.synchronize()
      return TatwoNativeToolResultRecord(callID: callID, output: "appended \(relative)")
    case "write":
      guard parts.count == 3 else { throw DriverError.tool("write requires path and text") }
      try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data((parts[2] + "\n").utf8).write(to: target, options: .atomic)
      return TatwoNativeToolResultRecord(callID: callID, output: "wrote \(relative)")
    default: throw DriverError.tool("tool not allowlisted: \(verb)")
    }
  }

  private static func saveMetadata(store: URL, runID: String, task: String, transport: String) throws {
    let directory = store.appendingPathComponent(runID, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let data = try JSONSerialization.data(
      withJSONObject: [
        "task": task,
        "transport": transport,
        "pid": String(getpid()),
      ],
      options: [.sortedKeys])
    try data.write(to: directory.appendingPathComponent("driver.json"), options: .atomic)
  }

  private static func loadMetadata(store: URL, runID: String) throws -> [String: String] {
    let url = store.appendingPathComponent(runID).appendingPathComponent("driver.json")
    guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: String] else {
      throw DriverError.invalidTask("invalid run metadata")
    }
    return object
  }
}
