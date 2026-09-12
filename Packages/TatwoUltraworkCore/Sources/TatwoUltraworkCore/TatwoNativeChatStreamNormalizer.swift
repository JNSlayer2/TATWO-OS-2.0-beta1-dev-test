import CryptoKit
import Darwin
import Foundation

public final class TatwoNativeChatStreamNormalizer: @unchecked Sendable {
  private let lock = NSLock()
  private var buffer = ""
  private var pendingActivityEvents: [ChatActivityEventV1] = []
  private var activeActivityIDs: [String: [String]] = [:]
  private var activitySequence = 0
  private var pendingGrokEventKind: TatwoNativeChatEventKind?
  private var pendingGrokText = ""
  private var pendingGrokRawType: String?
  private var immediatelyEmittedGrokKinds:
    Set<TatwoNativeChatEventKind> = []
  private let grokCoalescingCharacterThreshold = 25
  private let engine: TatwoNativeChatEngine
  private let streamFormat: TatwoNativeChatStreamFormat
  private let emitsSessionEvents: Bool
  private let emitsActivityEvents: Bool
  private let activityTurnID: String
  private let usageRecorder:
    @Sendable (String, Int?, Int?) -> Void
  /// Launch attempt / generation for activity identity (bridge retry = 2).
  private let activityAttempt: Int

  public init(
    engine: TatwoNativeChatEngine,
    streamFormat: TatwoNativeChatStreamFormat = .genericJSONL,
    emitsSessionEvents: Bool = true,
    activityTurnID: String? = nil,
    activityAttempt: Int = 1,
    emitsActivityEvents: Bool = false,
    usageRecorder:
      @escaping @Sendable (String, Int?, Int?) -> Void = {
        provider, inputTokens, outputTokens in
        TatwoLocalUsageMeter.recordShared(
          provider: provider,
          inputTokens: inputTokens,
          outputTokens: outputTokens)
      }
  ) {
    self.engine = engine
    self.streamFormat = streamFormat
    self.emitsSessionEvents = emitsSessionEvents
    self.emitsActivityEvents = emitsActivityEvents
    self.activityTurnID = activityTurnID ?? UUID().uuidString
    self.activityAttempt = max(1, activityAttempt)
    self.usageRecorder = usageRecorder
  }

  public func consume(_ chunk: String) -> [TatwoNativeChatEvent] {
    lock.lock()
    defer { lock.unlock() }
    buffer += chunk
    var events: [TatwoNativeChatEvent] = []
    while let newline = buffer.firstIndex(of: "\n") {
      let line = String(buffer[..<newline])
      buffer.removeSubrange(...newline)
      events.append(contentsOf: parse(line: line))
    }
    return events
  }

  public func flush() -> [TatwoNativeChatEvent] {
    lock.lock()
    defer { lock.unlock() }
    let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return streamFormat == .grokStreamingJSON
        ? flushPendingGrokEvent()
        : []
    }
    buffer = ""
    var events = parse(line: trimmed)
    if streamFormat == .grokStreamingJSON {
      events.append(contentsOf: flushPendingGrokEvent())
    }
    return events
  }

  /// Structured activity events are drained separately so existing
  /// transcript-facing `consume`/`flush` behavior remains unchanged.
  public func drainActivityEvents() -> [ChatActivityEventV1] {
    lock.lock()
    defer { lock.unlock() }
    let events = pendingActivityEvents
    pendingActivityEvents.removeAll(keepingCapacity: true)
    return events
  }

  private func parse(line: String) -> [TatwoNativeChatEvent] {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }
    if streamFormat == .grokStreamingJSON {
      return parseGrokStreamingJSON(line: trimmed)
    }
    guard let data = trimmed.data(using: .utf8),
          let value = try? JSONSerialization.jsonObject(with: data)
    else {
      if Self.isLikelyCLIDiagnostic(trimmed) { return [] }
      return [.init(engine: engine, kind: .raw, text: trimmed)]
    }

    var events: [TatwoNativeChatEvent] = []
    if emitsSessionEvents, let sessionID = Self.firstString(
      in: value,
      keys: ["session_id", "sessionId", "conversation_id", "conversationId", "thread_id", "threadId"]
    ), Self.looksLikeSessionID(sessionID) {
      events.append(.init(engine: engine, kind: .session, text: sessionID, sessionID: sessionID))
    }

    let rawType = Self.topLevelString(in: value, keys: ["type", "event", "status"])
    let itemType = Self.string(in: value, path: ["item", "type"])
    let resultIsError = Self.bool(in: value, path: ["is_error"]) == true
    let loweredRawType = rawType?.lowercased() ?? ""
    let activityTurnID = self.activityTurnID
    let activityText = Self.bestToolUseText(in: value)
      ?? Self.fallbackActivityText(rawType: rawType, itemType: itemType)
    if engine == .codex,
       let reconnectProgress = Self.codexReconnectProgress(
         in: value,
         rawType: rawType)
    {
      events.append(.init(
        engine: engine,
        kind: .thinking,
        text: "Reconnecting... \(reconnectProgress.attempt)/\(reconnectProgress.maximumAttempts)",
        rawType: rawType,
        reconnectProgress: reconnectProgress))
      return events
    }
    if loweredRawType == "turn.completed" {
      let degraded = Self.bool(in: value, path: ["degraded"]) == true
      let errorKind = Self.string(in: value, path: ["error_kind"])?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if degraded || errorKind?.isEmpty == false {
        let kind = (errorKind?.isEmpty == false ? errorKind! : "degraded_completion")
        let resetAt = Self.string(in: value, path: ["reset_at"])?
          .trimmingCharacters(in: .whitespacesAndNewlines)
        let message = resetAt?.isEmpty == false
          ? "\(kind)；reset \(resetAt!)"
          : kind
        events.append(.init(engine: engine, kind: .failure, text: message, rawType: rawType))
        return events
      }
      if engine == .codex {
        usageRecorder(
          "codex-gpt",
          Self.int(in: value, path: ["usage", "input_tokens"]),
          Self.int(in: value, path: ["usage", "output_tokens"]))
      }
      if let object = value as? [String: Any],
        let continuation = object["gateway_continuation"]
      {
        guard JSONSerialization.isValidJSONObject(continuation),
          let data = try? JSONSerialization.data(
            withJSONObject: continuation,
            options: [.sortedKeys]),
          let receipt = try? JSONDecoder().decode(
            TatwoGatewayContinuationReceiptV1.self,
            from: data),
          let normalized = try? JSONEncoder().encode(receipt),
          let text = String(data: normalized, encoding: .utf8)
        else {
          events.append(.init(
            engine: engine,
            kind: .failure,
            text: "gateway_continuation_receipt_invalid",
            rawType: rawType))
          return events
        }
        events.append(.init(
          engine: engine,
          kind: .continuation,
          text: text,
          rawType: rawType))
      }
    }
    if Self.isCodexActivityEndControl(loweredRawType) {
      emitActivityEvent(
        value: value,
        rawType: rawType,
        itemType: itemType,
        text: activityText,
        turnID: activityTurnID,
        resultIsError: resultIsError,
        forceTerminal: loweredRawType != "codex/event/exec_command_output_delta")
    }
    if let controlEvents = Self.codexConditionalControlEvents(
      in: value,
      loweredType: loweredRawType,
      engine: engine
    ) {
      events.append(contentsOf: controlEvents)
      return events
    }
    let eventKind = Self.kind(forRawType: rawType, itemType: itemType, resultIsError: resultIsError)
    if engine == .claude,
       loweredRawType == "result",
       !resultIsError,
       Self.string(in: value, path: ["subtype"]) == "success"
    {
      usageRecorder(
        "claude",
        Self.int(in: value, path: ["usage", "input_tokens"]),
        Self.int(in: value, path: ["usage", "output_tokens"]))
    }
    let extractedText: String?
    if eventKind == .toolUse {
      extractedText = Self.bestToolUseText(in: value)
        ?? Self.fallbackActivityText(rawType: rawType, itemType: itemType)
    } else if eventKind == .thinking {
      if Self.isCodexRawReasoningContentEvent(loweredRawType) {
        extractedText = Self.fallbackActivityText(rawType: rawType, itemType: itemType)
      } else {
        extractedText = Self.bestText(in: value, engine: engine)
          ?? Self.fallbackActivityText(rawType: rawType, itemType: itemType)
      }
    } else {
      extractedText = Self.bestText(in: value, engine: engine)
    }
    if let text = extractedText, !text.isEmpty {
      if eventKind == .toolUse && !Self.isCodexActivityEndControl(loweredRawType) {
        emitActivityEvent(
          value: value,
          rawType: rawType,
          itemType: itemType,
          text: text,
          turnID: activityTurnID,
          resultIsError: resultIsError,
          forceTerminal: false)
      }
      if Self.shouldSuppressText(rawType: rawType, itemType: itemType, resultIsError: resultIsError, text: text) {
        return events
      }
      events.append(.init(engine: engine, kind: eventKind, text: text, rawType: rawType))
    } else if eventKind == .failure, let rawType, !rawType.isEmpty {
      events.append(.init(engine: engine, kind: .failure, text: "[\(rawType)]", rawType: rawType))
    }

    if !events.isEmpty || Self.isKnownControlEvent(rawType: rawType, itemType: itemType) {
      return events
    }
    return [.init(engine: engine, kind: .raw, text: trimmed, rawType: rawType)]
  }

  private func parseGrokStreamingJSON(
    line: String
  ) -> [TatwoNativeChatEvent] {
    guard let data = line.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data)
        as? [String: Any]
    else {
      // Grok may interleave ANSI diagnostics and a terminal `Error:` line
      // with stdout JSONL. They are not assistant-visible protocol events.
      return []
    }
    let rawType = (object["type"] as? String)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let loweredType = rawType?.lowercased() ?? ""
    var events: [TatwoNativeChatEvent] = []
    if rawType == nil,
      let text = object["text"] as? String,
      !text.isEmpty
    {
      events.append(.init(
        engine: engine,
        kind: .message,
        text: text))
      return events
    }
    let text = (object["data"] as? String)
      ?? (object["message"] as? String)
    switch loweredType {
    case "end":
      events.append(contentsOf: flushPendingGrokEvent())
      immediatelyEmittedGrokKinds.removeAll(keepingCapacity: true)
      usageRecorder("grok", nil, nil)
      if emitsSessionEvents,
        let sessionID = object["sessionId"] as? String,
        Self.looksLikeSessionID(sessionID)
      {
        events.append(.init(
          engine: engine,
          kind: .session,
          text: sessionID,
          sessionID: sessionID,
          rawType: rawType))
      }
    case "thought":
      if let text, !text.isEmpty {
        events.append(contentsOf: coalesceGrokText(
          text,
          kind: .thinking,
          rawType: rawType))
      }
    case "text":
      if let text, !text.isEmpty {
        events.append(contentsOf: coalesceGrokText(
          text,
          kind: .message,
          rawType: rawType))
      }
    case "error":
      events.append(contentsOf: flushPendingGrokEvent())
      let visibleErrorText = text?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      events.append(.init(
        engine: engine,
        kind: .failure,
        text: visibleErrorText.isEmpty ? "[error]" : visibleErrorText,
        rawType: rawType))
    default:
      // Forward compatibility: unknown Grok event types are intentionally
      // ignored rather than surfaced as raw transcript noise or crashes.
      break
    }
    return events
  }

  private func coalesceGrokText(
    _ text: String,
    kind: TatwoNativeChatEventKind,
    rawType: String?
  ) -> [TatwoNativeChatEvent] {
    var events: [TatwoNativeChatEvent] = []
    if pendingGrokEventKind != nil, pendingGrokEventKind != kind {
      events.append(contentsOf: flushPendingGrokEvent())
    }
    if immediatelyEmittedGrokKinds.insert(kind).inserted {
      events.append(TatwoNativeChatEvent(
        engine: engine,
        kind: kind,
        text: text,
        rawType: rawType))
      return events
    }
    pendingGrokEventKind = kind
    pendingGrokRawType = rawType
    pendingGrokText += text
    if pendingGrokText.count >= grokCoalescingCharacterThreshold {
      events.append(contentsOf: flushPendingGrokEvent())
    }
    return events
  }

  private func flushPendingGrokEvent() -> [TatwoNativeChatEvent] {
    guard let kind = pendingGrokEventKind, !pendingGrokText.isEmpty else {
      pendingGrokEventKind = nil
      pendingGrokText = ""
      pendingGrokRawType = nil
      return []
    }
    let event = TatwoNativeChatEvent(
      engine: engine,
      kind: kind,
      text: pendingGrokText,
      rawType: pendingGrokRawType)
    pendingGrokEventKind = nil
    pendingGrokText = ""
    pendingGrokRawType = nil
    return [event]
  }

  private func emitActivityEvent(
    value: Any,
    rawType: String?,
    itemType: String?,
    text: String?,
    turnID: String,
    resultIsError: Bool,
    forceTerminal: Bool
  ) {
    guard emitsActivityEvents else { return }
    let loweredRawType = rawType?.lowercased() ?? ""
    let loweredItemType = itemType?.lowercased() ?? ""
    let isToolEvent = loweredRawType.contains("tool")
      || loweredRawType.contains("command")
      || loweredRawType.contains("patch")
      || loweredRawType.contains("web_search")
      || loweredRawType.contains("terminal_interaction")
      || loweredItemType.contains("tool")
      || loweredItemType.contains("command")
      || loweredItemType.contains("function")
    guard isToolEvent else { return }

    let terminal = forceTerminal
      || loweredRawType == "item.completed"
      || loweredItemType.contains("completed")
      || loweredRawType.contains("task_complete")
      || loweredRawType.contains("_end")
    let exitCode = Self.scalarString(in: value, path: ["item", "exit_code"])
    let failed = resultIsError
      || Self.string(in: value, path: ["item", "status"])?.lowercased().contains("fail") == true
      || Self.string(in: value, path: ["status"])?.lowercased().contains("fail") == true
      || (exitCode != nil && exitCode != "0")
    let status: ChatActivityStatusV1 = failed ? .failed : (terminal ? .succeeded : .running)
    let kind = Self.activityKind(rawType: rawType, itemType: itemType, text: text)
    let eventDate = Self.activityDate(in: value)
    let activityID = activityID(
      value: value,
      rawType: rawType,
      itemType: itemType,
      terminal: terminal)
    let label = Self.activityLabel(kind: kind, rawType: rawType, itemType: itemType)
    let detail = text?.trimmingCharacters(in: .whitespacesAndNewlines)
    pendingActivityEvents.append(
      ChatActivityEventV1(
        id: activityID,
        kind: kind,
        label: label,
        detail: detail?.isEmpty == false ? detail : nil,
        startedAt: eventDate,
        endedAt: terminal ? eventDate : nil,
        status: status,
        turnID: turnID,
        attempt: activityAttempt,
        sourceType: rawType))
  }

  private func activityID(
    value: Any,
    rawType: String?,
    itemType: String?,
    terminal: Bool
  ) -> String {
    let explicitID = Self.string(in: value, path: ["item", "id"])
      ?? Self.string(in: value, path: ["call_id"])
      ?? Self.string(in: value, path: ["callId"])
      ?? Self.string(in: value, path: ["tool_call_id"])
      ?? Self.string(in: value, path: ["toolCallId"])
      ?? Self.string(in: value, path: ["item_id"])
      ?? Self.string(in: value, path: ["itemId"])
    if let explicitID, !explicitID.isEmpty {
      return explicitID
    }

    let family = Self.activityFamily(rawType: rawType, itemType: itemType)
    if terminal, var activeIDs = activeActivityIDs[family], let activeID = activeIDs.popLast() {
      activeActivityIDs[family] = activeIDs
      return activeID
    }
    activitySequence += 1
    // Include attempt so reset sequence on a new spawn cannot collide with a
    // prior attempt's synthetic IDs even before reducer attempt-scoping.
    let generatedID = "\(activityTurnID):a\(activityAttempt):\(family):\(activitySequence)"
    if !terminal {
      activeActivityIDs[family, default: []].append(generatedID)
    }
    return generatedID
  }

  private static func activityKind(
    rawType: String?,
    itemType: String?,
    text: String?
  ) -> ChatActivityKindV1 {
    let value = [rawType, itemType, text].compactMap { $0?.lowercased() }.joined(separator: " ")
    if value.contains("exec_command") || value.contains("command") || value.contains("terminal_interaction") {
      return .command
    }
    if value.contains("patch") || value.contains("edit") || value.contains("write") {
      return .fileEdit
    }
    if value.contains("view_image") || value.contains("file_read") || value.contains("read_file") {
      return .fileRead
    }
    if value.contains("web_fetch") {
      return .webFetch
    }
    if value.contains("web_search") || value.contains("search") || value.contains("grep") {
      return .search
    }
    if value.contains("mcp") || value.contains("dynamic_tool") {
      return .mcp
    }
    return .toolUse
  }

  private static func activityLabel(
    kind: ChatActivityKindV1,
    rawType: String?,
    itemType: String?
  ) -> String {
    switch kind {
    case .command: return "Command"
    case .fileEdit: return "File edit"
    case .fileRead: return "File read"
    case .webFetch: return "Web fetch"
    case .search: return "Search"
    case .mcp: return "MCP tool"
    case .thinking: return "Thinking"
    case .toolUse:
      return itemType ?? rawType ?? "Tool"
    case .unknown:
      return rawType ?? "Activity"
    }
  }

  private static func activityFamily(rawType: String?, itemType: String?) -> String {
    let source = (rawType ?? itemType ?? "tool").lowercased()
    return source
      .replacingOccurrences(of: "_begin", with: "")
      .replacingOccurrences(of: "_end", with: "")
      .replacingOccurrences(of: "_output_delta", with: "")
  }

  private static func activityDate(in value: Any) -> Date {
    let timestamp = firstString(
      in: value,
      keys: ["timestamp", "created_at", "createdAt", "completed_at", "completedAt"])
    if let timestamp,
       let date = ISO8601DateFormatter().date(from: timestamp) {
      return date
    }
    return Date()
  }

  private static func kind(forRawType rawType: String?, itemType: String?, resultIsError: Bool = false) -> TatwoNativeChatEventKind {
    let lowered = rawType?.lowercased() ?? ""
    let loweredItem = itemType?.lowercased() ?? ""
    if lowered == "result", resultIsError { return .failure }
    if lowered == "result" { return .raw }
    if lowered.contains("fail") || lowered.contains("error") || lowered.contains("warning") { return .failure }
    if lowered.contains("agent_message") { return .message }
    if lowered.contains("agent_reasoning")
      || lowered.contains("reasoning_content")
      || lowered.contains("reasoning_raw_content")
      || lowered.contains("plan_")
      || lowered.contains("approval_request")
      || lowered.contains("elicitation_request")
      || lowered.contains("request_user_input")
      || lowered.contains("mcp_startup_update")
      || lowered.contains("remote_task_created")
      || lowered.contains("undo_started")
      || lowered.contains("collab_waiting")
      || lowered.contains("collab_agent")
      || lowered.contains("collab_resume")
      || lowered.contains("collab_close")
      || lowered == "codex/event/task_started"
    {
      return .thinking
    }
    if lowered.contains("exec_command")
      || lowered.contains("mcp_tool_call")
      || lowered.contains("dynamic_tool_call")
      || lowered.contains("patch_apply")
      || lowered.contains("apply_patch")
      || lowered.contains("web_search")
      || lowered.contains("view_image_tool_call")
      || lowered.contains("terminal_interaction")
    {
      return .toolUse
    }
    if lowered == "item.completed" || lowered == "item.started" {
      if loweredItem.contains("tool") || loweredItem.contains("function") || loweredItem.contains("command") { return .toolUse }
      if loweredItem.contains("thinking") || loweredItem.contains("thought") || loweredItem.contains("reasoning") { return .thinking }
      if loweredItem.contains("error") { return .raw }
      return .message
    }
    if lowered.contains("tool") || lowered.contains("command") { return .toolUse }
    if lowered.contains("thinking") || lowered.contains("thought") { return .thinking }
    return .message
  }

  private static func codexReconnectProgress(
    in value: Any,
    rawType: String?
  ) -> TatwoNativeChatReconnectProgress? {
    guard rawType == "error",
      let object = value as? [String: Any],
      let message = object["message"] as? String
    else {
      return nil
    }
    let pattern =
      #"^Reconnecting\.\.\. ([1-9][0-9]*)/([1-9][0-9]*) \(stream disconnected before completion: ([^\r\n]+)\)$"#
    guard let regex = try? NSRegularExpression(pattern: pattern),
      let match = regex.firstMatch(
        in: message,
        range: NSRange(message.startIndex..<message.endIndex, in: message)),
      match.range == NSRange(message.startIndex..<message.endIndex, in: message),
      let attemptRange = Range(match.range(at: 1), in: message),
      let maximumRange = Range(match.range(at: 2), in: message),
      let detailRange = Range(match.range(at: 3), in: message),
      let attempt = Int(message[attemptRange]),
      let maximumAttempts = Int(message[maximumRange]),
      attempt <= maximumAttempts
    else {
      return nil
    }
    return TatwoNativeChatReconnectProgress(
      attempt: attempt,
      maximumAttempts: maximumAttempts,
      detail: String(message[detailRange]))
  }

  private static func isKnownControlEvent(rawType: String?, itemType: String?) -> Bool {
    let lowered = rawType?.lowercased() ?? ""
    if lowered == "system" || lowered == "rate_limit_event" {
      return true
    }
    if lowered == "thread.started" || lowered == "turn.started" || lowered == "turn.completed" {
      return true
    }
    if Self.isCodexActivityEndControl(lowered) {
      return true
    }
    if lowered == "item.completed", itemType?.lowercased() == "error" {
      return true
    }
    if Self.isCodexQuietControlEvent(lowered) {
      return true
    }
    if lowered == "item.started" || lowered == "item.completed" {
      let loweredItem = itemType?.lowercased() ?? ""
      if loweredItem.contains("command") || loweredItem.contains("tool") || loweredItem.contains("function") {
        return true
      }
    }
    return false
  }


  private static func isCodexActivityEndControl(_ loweredType: String) -> Bool {
    guard loweredType.hasPrefix("codex/event/") else { return false }
    if loweredType == "codex/event/task_complete" { return true }
    if loweredType == "codex/event/exec_command_output_delta" { return true }
    if loweredType == "codex/event/background_event" { return true }
    return loweredType.hasSuffix("_end")
  }

  private static func codexConditionalControlEvents(
    in value: Any,
    loweredType: String,
    engine: TatwoNativeChatEngine
  ) -> [TatwoNativeChatEvent]? {
    guard loweredType.hasPrefix("codex/event/") else { return nil }
    if loweredType == "codex/event/turn_aborted" {
      guard let text = Self.bestControlText(in: value, engine: engine)?
        .trimmingCharacters(in: .whitespacesAndNewlines),
        !text.isEmpty
      else {
        return []
      }
      if Self.isLikelyUserAbortText(text) {
        return [.init(engine: engine, kind: .thinking, text: "turn_aborted", rawType: "codex/event/turn_aborted")]
      }
      return [.init(engine: engine, kind: .failure, text: text, rawType: "codex/event/turn_aborted")]
    }
    if loweredType == "codex/event/deprecation_notice" {
      guard let text = Self.bestControlText(in: value, engine: engine)?
        .trimmingCharacters(in: .whitespacesAndNewlines),
        !text.isEmpty
      else {
        return []
      }
      return [.init(engine: engine, kind: .failure, text: text, rawType: "codex/event/deprecation_notice")]
    }
    return nil
  }

  private static func bestControlText(in value: Any, engine: TatwoNativeChatEngine) -> String? {
    firstText(
      in: value,
      preferredKeys: [
        "message", "reason", "error", "detail", "details", "notice", "summary", "text", "description"
      ]
    ) ?? bestText(in: value, engine: engine)
  }

  private static func isLikelyUserAbortText(_ text: String) -> Bool {
    let lowered = text.lowercased()
    return lowered.contains("user")
      || lowered.contains("cancel")
      || lowered.contains("stop")
      || lowered.contains("interrupt")
      || lowered.contains("中止")
      || lowered.contains("停止")
      || lowered.contains("取消")
  }

  private static func isCodexRawReasoningContentEvent(_ loweredType: String) -> Bool {
    guard loweredType.hasPrefix("codex/event/") else { return false }
    return loweredType.contains("reasoning_raw_content")
      || (loweredType.contains("raw_content") && loweredType.contains("reasoning"))
  }

  private static func isCodexQuietControlEvent(_ loweredType: String) -> Bool {
    guard loweredType.hasPrefix("codex/event/") else { return false }
    return [
      "codex/event/session_configured",
      "codex/event/get_history_entry_response",
      "codex/event/item_started",
      "codex/event/item_completed",
      "codex/event/user_message",
      "codex/event/turn_diff",
      "codex/event/mcp_list_tools_response",
      "codex/event/list_skills_response",
      "codex/event/list_remote_skills_response",
      "codex/event/remote_skill_downloaded",
      "codex/event/list_custom_prompts_response",
      "codex/event/raw_response_item",
      "codex/event/agent_reasoning_section_break",
      "codex/event/undo_completed",
      "codex/event/mcp_startup_complete",
      "codex/event/thread_rolled_back",
      "codex/event/thread_name_updated",
      "codex/event/token_count",
      "codex/event/deprecation_notice",
      "codex/event/shutdown_complete",
      "codex/event/entered_review_mode",
      "codex/event/exited_review_mode"
    ].contains(loweredType)
  }

  private static func shouldSuppressText(rawType: String?, itemType: String?, resultIsError: Bool, text: String) -> Bool {
    let loweredType = rawType?.lowercased() ?? ""
    let loweredItem = itemType?.lowercased() ?? ""
    if loweredType == "result", resultIsError == false {
      return true
    }
    if loweredType == "system" || loweredType == "rate_limit_event" {
      return true
    }
    if loweredType == "thread.started" || loweredType == "turn.started" || loweredType == "turn.completed" {
      return true
    }
    if Self.isCodexActivityEndControl(loweredType) {
      return true
    }
    if Self.isCodexQuietControlEvent(loweredType) {
      return true
    }
    if loweredType == "item.completed", loweredItem == "error" {
      return true
    }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty
  }

  private static func isLikelyCLIDiagnostic(_ line: String) -> Bool {
    if line.range(of: #"^\d{4}-\d{2}-\d{2}T.*\b(WARN|ERROR|INFO|DEBUG|TRACE)\b"#, options: .regularExpression) != nil {
      return true
    }
    if line.contains("unknown feature key in config:") { return true }
    return false
  }

  private static func looksLikeSessionID(_ value: String) -> Bool {
    value.count >= 8 && value.range(of: #"^[A-Za-z0-9_.:-]+$"#, options: .regularExpression) != nil
  }

  private static func firstString(in value: Any, keys: [String]) -> String? {
    if let dict = value as? [String: Any] {
      for key in keys {
        if let string = dict[key] as? String, !string.isEmpty { return string }
      }
      for candidate in dict.values {
        if let found = firstString(in: candidate, keys: keys) { return found }
      }
    } else if let array = value as? [Any] {
      for candidate in array {
        if let found = firstString(in: candidate, keys: keys) { return found }
      }
    }
    return nil
  }

  private static func topLevelString(in value: Any, keys: [String]) -> String? {
    guard let dict = value as? [String: Any] else { return nil }
    for key in keys {
      if let string = dict[key] as? String, !string.isEmpty { return string }
    }
    return nil
  }

  private static func string(in value: Any, path: [String]) -> String? {
    guard !path.isEmpty else { return value as? String }
    guard let dict = value as? [String: Any] else { return nil }
    return string(in: dict[path[0]] as Any, path: Array(path.dropFirst()))
  }

  private static func scalarString(in value: Any, path: [String]) -> String? {
    guard !path.isEmpty else {
      if let string = value as? String { return string }
      if let number = value as? NSNumber { return number.stringValue }
      return nil
    }
    guard let dict = value as? [String: Any] else { return nil }
    return scalarString(in: dict[path[0]] as Any, path: Array(path.dropFirst()))
  }

  private static func bool(in value: Any, path: [String]) -> Bool? {
    guard !path.isEmpty else { return value as? Bool }
    guard let dict = value as? [String: Any] else { return nil }
    return bool(in: dict[path[0]] as Any, path: Array(path.dropFirst()))
  }

  private static func int(in value: Any, path: [String]) -> Int? {
    guard !path.isEmpty else {
      return (value as? NSNumber)?.intValue
    }
    guard let dict = value as? [String: Any] else { return nil }
    return int(
      in: dict[path[0]] as Any,
      path: Array(path.dropFirst()))
  }

  private static func bestText(in value: Any, engine: TatwoNativeChatEngine) -> String? {
    let preferred: [String]
    switch engine {
    case .codex:
      preferred = ["delta", "text", "message", "output", "result", "summary", "content", "last_message", "lastMessage", "assistant_message", "assistantMessage"]
    case .claude:
      preferred = ["text", "content", "message", "delta", "output", "result", "summary"]
    }
    return firstText(in: value, preferredKeys: preferred)
  }

  private static func bestToolUseText(in value: Any) -> String? {
    let preferred = [
      "command", "cmd", "tool_name", "toolName", "tool", "server", "name", "function", "arguments",
      "input", "path", "filePath", "filename", "query", "description", "summary"
    ]
    guard let text = firstText(in: value, preferredKeys: preferred)?
      .trimmingCharacters(in: .whitespacesAndNewlines),
      !text.isEmpty
    else {
      return nil
    }
    return text
  }

  private static func fallbackActivityText(rawType: String?, itemType: String?) -> String? {
    let lowered = rawType?.lowercased() ?? ""
    let loweredItem = itemType?.lowercased() ?? ""
    if lowered.contains("exec_command") { return "exec_command" }
    if lowered.contains("mcp_tool_call") { return "mcp_tool_call" }
    if lowered.contains("dynamic_tool_call") { return "dynamic_tool_call" }
    if lowered.contains("approval_request") { return "approval_request" }
    if lowered.contains("elicitation_request") || lowered.contains("request_user_input") { return "request_user_input" }
    if lowered.contains("mcp_startup_update") { return "mcp_startup" }
    if lowered.contains("remote_task_created") { return "remote_task" }
    if lowered.contains("patch_apply") || lowered.contains("apply_patch") { return "apply_patch" }
    if lowered.contains("web_search") { return "web_search" }
    if lowered.contains("view_image_tool_call") { return "view_image_tool_call" }
    if lowered.contains("terminal_interaction") { return "terminal_interaction" }
    if lowered.contains("collab_waiting") { return "collab_waiting" }
    if lowered.contains("collab_agent") || lowered.contains("collab_resume") || lowered.contains("collab_close") { return "collab_agent" }
    if lowered.contains("plan_") { return "plan_update" }
    if lowered.contains("undo_started") { return "undo_started" }
    if lowered.contains("turn_aborted") { return "turn_aborted" }
    if lowered.contains("agent_reasoning") || lowered.contains("reasoning_content") || lowered.contains("reasoning_raw_content") { return "agent_reasoning" }
    if lowered == "codex/event/task_started" { return "task_started" }
    if lowered == "item.started" || lowered == "item.completed", !loweredItem.isEmpty {
      return loweredItem
    }
    return nil
  }

  private static func firstText(in value: Any, preferredKeys: [String]) -> String? {
    if let string = value as? String { return string }
    if let dict = value as? [String: Any] {
      for key in preferredKeys {
        guard let candidate = dict[key] else { continue }
        if let text = firstText(in: candidate, preferredKeys: preferredKeys), !text.isEmpty { return text }
      }
      for (key, candidate) in dict where !Self.isControlScalarKey(key) {
        if candidate is [String: Any] || candidate is [Any],
           let text = firstText(in: candidate, preferredKeys: preferredKeys), !text.isEmpty {
          return text
        }
      }
    } else if let array = value as? [Any] {
      let joined = array.compactMap { firstText(in: $0, preferredKeys: preferredKeys) }
        .filter { !$0.isEmpty }
        .joined(separator: "")
      return joined.isEmpty ? nil : joined
    }
    return nil
  }

  private static func isControlScalarKey(_ key: String) -> Bool {
    [
      "type", "event", "status", "id", "thread_id", "threadId", "session_id", "sessionId",
      "conversation_id", "conversationId", "created_at", "createdAt"
    ].contains(key)
  }
}
