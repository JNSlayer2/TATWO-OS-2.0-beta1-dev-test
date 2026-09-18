import CryptoKit
import Darwin
import Foundation

public enum TatwoChatCommandPlanner {
  private static let uuidHexCharacters = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
  static let gatewayPromptFilePrefix = ".tatwo-gateway-prompt-"
  static let gatewayContinuationFilePrefix =
    ".tatwo-gateway-continuation-"
  static let gatewayPromptMaximumUTF8Bytes = 8 * 1024 * 1024
  static let gatewayContinuationMaximumUTF8Bytes = 16 * 1024
  // This is an inactivity timeout, not a target turn duration. The gateway
  // emits semantic SSE heartbeats while a provider is still working, so an
  // active long office turn can continue while a truly silent route remains
  // bounded by the matching 10-minute Chat watchdog.
  static func tomlBasicStringEscaped(_ value: String) -> String {
    value.replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
  }

  public static let gatewayDirectInactivityTimeoutMilliseconds = 600_000

  public static func sanitizedCodexResumeSessionID(_ value: String?) -> String? {
    cleanedResumeSessionID(value)
  }

  public static func sanitizedClaudeResumeSessionID(_ value: String?) -> String? {
    guard let id = cleanedResumeSessionID(value) else { return nil }
    // Claude CLI `--resume` hangs when given a Codex App / Codex CLI thread id.
    // Codex thread/session ids are UUIDv7-shaped; native Claude sessions in
    // current receipts are UUIDv4 or explicit `claude-*` ids. Use the UUID
    // version nibble instead of the current `019f` time prefix so this stays
    // valid after UUIDv7 timestamps roll past today's prefix window.
    guard !looksLikeCodexThreadSessionID(id) else { return nil }
    return id
  }

  public static func sanitizedGrokResumeSessionID(_ value: String?) -> String? {
    cleanedResumeSessionID(value)
  }

  public static func looksLikeCodexThreadSessionID(_ value: String) -> Bool {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if uuidVersionNibble(trimmed) == "7" {
      return true
    }
    // Backward-compatible guard for already-persisted transient/local Codex ids
    // that were observed with the 019f prefix but are not canonical UUID text.
    return trimmed.hasPrefix("019f")
  }

  private static func uuidVersionNibble(_ value: String) -> Character? {
    let groups = value.split(separator: "-", omittingEmptySubsequences: false)
    let expectedLengths = [8, 4, 4, 4, 12]
    guard groups.count == expectedLengths.count else { return nil }
    for (group, expectedLength) in zip(groups, expectedLengths) {
      guard group.count == expectedLength else { return nil }
      guard group.unicodeScalars.allSatisfy({ uuidHexCharacters.contains($0) }) else { return nil }
    }
    return groups[2].first
  }

  private static func cleanedResumeSessionID(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    guard !trimmed.hasPrefix("tatwo-gateway-") else { return nil }
    return trimmed
  }

  public static func requiresTatwoComputerHost(for currentVisibleTurn: String) -> Bool {
    guard let visibleTurn = validatedCurrentComputerHostIntentText(
      currentVisibleTurn)
    else {
      return false
    }
    // Strip quoted examples before clause tokenization. Splitting first can cut
    // an inline quote at `;` / `，`, leaving the latter half looking like a
    // fresh imperative (for example: `...; Use Computer Use ...`).
    let clauses = removingQuotedComputerHostExamples(
      from: visibleTurn.lowercased())
      .replacingOccurrences(
        of:
          #"\b(?:but|however|instead|actually|now|then|finally)\b|(?:但是|但|不過|不过|改為|改为|改成|現在|现在|最後|最后|接著|接着|然後|然后)"#,
        with: "\n__tatwo_intent_override__\n",
        options: .regularExpression)
      .components(
        separatedBy: CharacterSet(
          charactersIn: "\n\r。！？；;，,"))
    var currentDecision: Bool?
    var toolDenialCeiling = false
    var nextClauseMayOverride = false
    for clause in clauses {
      let trimmed = clause.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed == "__tatwo_intent_override__" {
        nextClauseMayOverride = true
        continue
      }
      let clauseMayOverride = nextClauseMayOverride
      nextClauseMayOverride = false
      let normalized = trimmed
      guard !normalized.isEmpty else { continue }
      if isTextOnlyOrToolFreeClause(normalized) {
        currentDecision = false
        toolDenialCeiling = true
        continue
      }
      let hasExplicitComputerUse = normalized.range(
        of: #"computer[\s_-]*use|plugin://computer-use|@電腦|電腦操作"#,
        options: .regularExpression) != nil
      let hasUIAction = normalized.range(
        of: #"打開|開啟|點擊|按下|輸入|拖曳|滑動|查看畫面|檢查畫面|操作"#,
        options: .regularExpression) != nil
      let hasUITarget = normalized.range(
        of: #"\bapp\b|應用程式|視窗|畫面|介面|瀏覽器|arc|brave|chrome|safari|tatwo os|os app"#,
        options: .regularExpression) != nil
      guard hasExplicitComputerUse || (hasUIAction && hasUITarget) else {
        continue
      }
      if clauseNegatesComputerHostIntent(normalized) {
        currentDecision = false
        toolDenialCeiling = true
        continue
      }
      // A capability name in a quote, error report, or historical explanation is
      // context rather than host authority. Ambiguous mentions stay text-only.
      guard clauseAffirmativelyRequestsComputerHost(normalized) else {
        continue
      }
      // A pasted/history block cannot silently reopen a current-turn tool
      // denial. Reopening requires an explicit contrast/override connector.
      guard !toolDenialCeiling || clauseMayOverride else {
        continue
      }
      currentDecision = true
      toolDenialCeiling = false
    }
    return currentDecision ?? false
  }

  /// Computer-host authority is a current visible-turn decision. Historical
  /// transcript bridges and other hidden runtime contracts are context for the
  /// model, never user authority to acquire a host lease or inject tools.
  ///
  /// The caller must supply the current visible turn as a separate value.
  /// Reserved transcript/hidden-context framing is never parsed here: it may
  /// be incomplete, inline, quoted, or forged by user text. Treating any such
  /// marker as a boundary would let untrusted text choose which clause grants
  /// host authority, so malformed or flattened input fails closed.
  private static func validatedCurrentComputerHostIntentText(
    _ turn: String
  ) -> String? {
    let reservedFramingPatterns = [
      #"\[\s*/?\s*hidden\b"#,
      #"\bcurrent\s+user\s+request\s*:"#,
      #"\bconversation\s+history\s+from\s+this\s+same\s+tatwo\s+thread\s*:"#,
      #"(?m)^\s*(?:>\s*)?\[(?:user|assistant|system)\](?:\s|$)"#,
    ]
    for pattern in reservedFramingPatterns
    where turn.range(
      of: pattern,
      options: [.regularExpression, .caseInsensitive]) != nil
    {
      return nil
    }
    return turn
  }

  private static func isTextOnlyOrToolFreeClause(_ clause: String) -> Bool {
    clause.range(
      of: #"(?:只|僅|仅).{0,12}(?:純文字|纯文字|文字(?:回答|回覆|回复))|\btext[\s-]*only\b|\b(?:respond|reply|return|provide)(?:\s+with)?\s+text\s+only\b"#,
      options: .regularExpression) != nil
      || clause.range(
        of: #"(?:不要|別|别|請勿|请勿|禁止|不准|不可|不用|無需|无需|不需要|毋須|毋须).{0,20}(?:任何)?(?:工具|tool)|\b(?:do\s+not|don['’]?t|never|must\s+not|mustn['’]?t|should\s+not|shouldn['’]?t|cannot|can['’]?t|no\s+need\s+to|avoid)\b.{0,32}\b(?:call|use|invoke|request|run|ask\s+for)?\s*(?:any\s+)?tools?\b|\b(?:without\s+tools?|no\s+tools?|no\s+tool\s+calls?)\b"#,
        options: .regularExpression) != nil
  }

  private static func removingQuotedComputerHostExamples(from clause: String) -> String {
    clause.replacingOccurrences(
      of: #""[^"]*"|“[^”]*”|「[^」]*」|『[^』]*』|'[^']*'|‘[^’]*’|`[^`]*`"#,
      with: " ",
      options: .regularExpression)
  }

  private static func clauseAffirmativelyRequestsComputerHost(_ clause: String) -> Bool {
    let explicitIntent =
      #"(?:computer[\s_-]*use|plugin://computer-use|@電腦|電腦操作)"#
    if clause.range(
      of:
        #"^(?:(?:please|can\s+you|could\s+you|would\s+you|i\s+(?:want|need)\s+you\s+to)\s+)?(?:use|invoke|run|enable|request)\s+(?:the\s+)?"#
        + explicitIntent,
      options: .regularExpression) != nil
    {
      return true
    }
    if clause.range(
      of:
        #"^(?:(?:本輪|本轮|這次|这次|本次).{0,6})?(?:請|请|直接|務必|务必|幫我|帮我|替我|麻煩|麻烦|煩請|烦请)?(?:使用|用|呼叫|调用|啟用|启用|要求).{0,8}"#
        + explicitIntent,
      options: .regularExpression) != nil
    {
      return true
    }
    let action =
      #"(?:打開|開啟|點擊|按下|輸入|拖曳|滑動|查看畫面|檢查畫面|操作)"#
    let target =
      #"(?:\bapp\b|應用程式|視窗|畫面|介面|瀏覽器|arc|brave|chrome|safari|tatwo os|os app)"#
    return clause.range(
      of:
        #"^(?:(?:(?:本輪|本轮|這次|这次|本次).{0,6})?(?:請|请|直接|幫我|帮我|替我|麻煩|麻烦|煩請|烦请).{0,12})?"#
        + action + #".{0,24}"# + target,
      options: .regularExpression) != nil
  }

  private static func clauseNegatesComputerHostIntent(_ clause: String) -> Bool {
    let intent =
      #"(?:computer[\s_-]*use|plugin://computer-use|@電腦|電腦操作|打開|開啟|點擊|按下|輸入|拖曳|滑動|查看畫面|檢查畫面|操作)"#
    return clause.range(
      of: #"(?:不要|別|别|請勿|请勿|禁止|不准|不可|不用|無需|无需|不需要|毋須|毋须|不使用|不要求).{0,40}"# + intent,
      options: .regularExpression) != nil
      || clause.range(
        of: #"\b(?:do\s+not|don['’]?t|never|must\s+not|mustn['’]?t|should\s+not|shouldn['’]?t|cannot|can['’]?t|no\s+need\s+to|avoid|without)\b.{0,40}"# + intent,
        options: .regularExpression) != nil
      || clause.range(
        of: intent + #".{0,20}\b(?:is\s+)?not\s+(?:requested|required|allowed|needed)\b"#,
        options: .regularExpression) != nil
      || clause.range(
        of: intent + #".{0,20}\b(?:(?:should|must)\s+not|(?:should|must)n['’]?t|cannot|can['’]?t)\s+(?:be\s+)?(?:used|called|invoked|requested|run)\b"#,
        options: .regularExpression) != nil
      || clause.range(
        of: intent + #".{0,20}\b(?:is\s+)?(?:forbidden|prohibited|disallowed)\b"#,
        options: .regularExpression) != nil
      || clause.range(
        of: intent + #".{0,12}(?:禁止使用|不得使用|不可使用|不准使用|請勿使用|请勿使用|不應使用|不应使用|不該使用|不该使用|不要用|別用|别用|無需使用|无需使用|不需要使用|毋須使用|毋须使用)"#,
      options: .regularExpression) != nil
  }

  /// Classifies only the exact current visible turn. Scenario names and hidden
  /// history never grant tools. Goal phase/status may reduce the ceiling, but
  /// only an explicit current-turn development request can open the native
  /// runtime.
  public static func nativeDevelopmentAccess(
    currentVisibleTurn: String,
    mode: TatwoChatCommandMode,
    interactionMode: TatwoChatInteractionMode,
    scenarioPhase: TatwoScenarioPhase,
    contractStatus: GoalRunStatus?
  ) -> TatwoNativeDevelopmentAccess {
    nativeDevelopmentDecision(
      currentVisibleTurn: currentVisibleTurn,
      mode: mode,
      interactionMode: interactionMode,
      scenarioPhase: scenarioPhase,
      contractStatus: contractStatus).access
  }

  public static func nativeDevelopmentDecision(
    currentVisibleTurn: String,
    mode: TatwoChatCommandMode,
    interactionMode: TatwoChatInteractionMode,
    scenarioPhase: TatwoScenarioPhase,
    contractStatus: GoalRunStatus?
  ) -> TatwoNativeDevelopmentTurnDecision {
    guard mode == .chat,
      let visibleTurn = validatedCurrentComputerHostIntentText(
        currentVisibleTurn)
    else {
      return TatwoNativeDevelopmentTurnDecision(
        requested: false,
        access: .none)
    }
    let clauses = removingQuotedComputerHostExamples(
      from: visibleTurn.lowercased())
      .replacingOccurrences(
        of:
          #"\b(?:but|however|instead|actually|now|then|finally)\b|(?:但是|但|不過|不过|改為|改为|改成|現在|现在|最後|最后|接著|接着|然後|然后)"#,
        with: "\n__tatwo_intent_override__\n",
        options: .regularExpression)
      .components(
        separatedBy: CharacterSet(
          charactersIn: "\n\r。！？；;，,"))

    var current: TatwoNativeDevelopmentAccess = .none
    var allToolsDenied = false
    var mutationDenied = false
    var nextClauseMayOverride = false
    var hasDevelopmentRequest = false
    var nativeToolChecklistOpen = false
    for rawClause in clauses {
      let clause = rawClause.trimmingCharacters(
        in: .whitespacesAndNewlines)
      if clause == "__tatwo_intent_override__" {
        nextClauseMayOverride = true
        continue
      }
      let mayOverride = nextClauseMayOverride
      nextClauseMayOverride = false
      guard !clause.isEmpty else { continue }

      if isPastedDevelopmentContextLead(clause) {
        current = .none
        allToolsDenied = true
        nativeToolChecklistOpen = false
        continue
      }
      if isTextOnlyOrToolFreeClause(clause) {
        current = .none
        allToolsDenied = true
        mutationDenied = true
        nativeToolChecklistOpen = false
        continue
      }
      if clauseDeniesDevelopmentMutation(clause) {
        if current == .mutation { current = .readOnly }
        mutationDenied = true
      }

      if isExplicitNativeToolChecklistLead(clause) {
        nativeToolChecklistOpen = true
        continue
      }
      let directClauseAccess = affirmativeDevelopmentAccess(in: clause)
      let clauseAccess =
        directClauseAccess != .none
          ? directClauseAccess
          : (
            nativeToolChecklistOpen
              ? numberedNativeToolChecklistAccess(in: clause)
              : .none
          )
      guard clauseAccess != .none else { continue }
      guard !allToolsDenied || mayOverride else { continue }
      if mayOverride {
        allToolsDenied = false
      }
      hasDevelopmentRequest = true
      switch clauseAccess {
      case .none:
        break
      case .readOnly:
        current = .readOnly
      case .mutation:
        guard !mutationDenied else { continue }
        current = .mutation
      }
    }

    guard hasDevelopmentRequest else {
      return TatwoNativeDevelopmentTurnDecision(
        requested: false,
        access: .none)
    }
    guard let contractStatus,
      ![
        GoalRunStatus.succeeded,
        .failed,
        .cancelled,
        .passed,
        .rollbackRequired,
        .superseded,
      ].contains(contractStatus)
    else {
      return TatwoNativeDevelopmentTurnDecision(
        requested: true,
        access: .none)
    }
    let planCapped =
      interactionMode == .plan || scenarioPhase == .plan
    if planCapped {
      return TatwoNativeDevelopmentTurnDecision(
        requested: true,
        access: current == .none ? .none : .readOnly)
    }
    if scenarioPhase == .goal {
      return TatwoNativeDevelopmentTurnDecision(
        requested: true,
        access: current == .none ? .none : .readOnly)
    }
    guard scenarioPhase == .loops else {
      return TatwoNativeDevelopmentTurnDecision(
        requested: true,
        access: .none)
    }
    if current == .mutation,
      ![GoalRunStatus.dispatching, .running].contains(contractStatus)
    {
      return TatwoNativeDevelopmentTurnDecision(
        requested: true,
        access: .readOnly)
    }
    return TatwoNativeDevelopmentTurnDecision(
      requested: true,
      access: current)
  }

  private static func isPastedDevelopmentContextLead(
    _ clause: String
  ) -> Bool {
    clause.range(
      of:
        #"^(?:issue\s+(?:body|content)|(?:以下|下面|下列).{0,8}issue\s*(?:內容|内容)|issue\s*(?:內容|内容))\s*[:：]?$"#,
      options: .regularExpression) != nil
  }

  private static func affirmativeDevelopmentAccess(
    in clause: String
  ) -> TatwoNativeDevelopmentAccess {
    let explicitToolRequestPrefix =
      #"(?:^|[、；;，,]|\band\b)\s*(?!(?:不要|別|别|禁止|請勿|请勿|不准|不可|不得|不用|無需|无需|不需要|do\s+not|don['’]?t|never)\b)(?:(?:請|请|直接|務必|务必|幫我|帮我|替我|麻煩|麻烦|實際|实际|please)\s*)*(?:(?:依序|逐項|逐项|one\s+by\s+one)\s*)?(?:使用|用|執行|执行|呼叫|调用|use|invoke|call)\s+(?:tatwo\s*(?:內建|内建|built[\s-]*in)\s+)?"#
    let explicitMutationTool =
      #"(?:write_file|edit_file|run_command|build|test|rollback)"#
    if clause.range(
      of: explicitToolRequestPrefix + #"\b"# + explicitMutationTool + #"\b"#,
      options: .regularExpression) != nil
    {
      return .mutation
    }
    let explicitReadOnlyTool =
      #"(?:list_files|read_file|search|git_status|git_diff)"#
    if clause.range(
      of: explicitToolRequestPrefix + #"\b"# + explicitReadOnlyTool + #"\b"#,
      options: .regularExpression) != nil
    {
      return .readOnly
    }
    if clause.range(
      of:
        #"^(?:(?:請|请|直接|務必|务必|幫我|帮我|替我|麻煩|麻烦|please)\s*)?(?:執行測試|执行测试|跑測試|跑测试|run\s+tests?|run\s+build)\s*$"#,
      options: .regularExpression) != nil
    {
      return .mutation
    }
    if clause.range(
      of:
        #"^(?:(?:請|请|務必|务必|幫我|帮我|替我|麻煩|麻烦|please)\s*)?(?:直接\s*)?(?:施工|開始施工|开始施工|進行施工|进行施工)\s*[:：]?$"#,
      options: .regularExpression) != nil
    {
      return .mutation
    }
    if clause.range(
      of:
        #"^(?:(?:請|请|直接|幫我|帮我|替我|麻煩|麻烦|please)\s*)?(?:git\s+status|git\s+diff|pwd)\s*$"#,
      options: .regularExpression) != nil
    {
      return .readOnly
    }
    if clause.range(
      of:
        #"^(?:(?:請|请|直接|務必|务必|幫我|帮我|替我|麻煩|麻烦|please)\s*)?(?:實際|实际)?\s*(?:使用|用|use)\s+(?:read|search|shell)(?:\s*/\s*(?:read|search|shell))*\b"#,
      options: .regularExpression) != nil
    {
      return .readOnly
    }
    let explicitRequestLead =
      #"(?:請|请|直接|務必|务必|幫我|帮我|替我|麻煩|麻烦|實際|实际|開始|开始|繼續|继续|完成|使用|用|只|僅|仅|please|can\s+you(?:\s+please)?|could\s+you(?:\s+please)?|would\s+you(?:\s+please)?|i\s+(?:want|need)\s+you\s+to)\s*"#
    let optionalRequestLead =
      #"(?:"# + explicitRequestLead + #")?"#
    let explicitObjectRequestLead =
      #"(?:"# + explicitRequestLead + #")?(?:把|將|将)\s*"#
    let mutationAction =
      #"(?:修改|修好|修復|修复|改碼|改码|改(?:程式|程序|代碼|代码)|編輯|编辑|寫入|写入|新增|建立|創建|创建|實作|实现|優化|优化|重做|重構|重构|減碼|减码|補齊|补齐|隔離|隔离|刪除|删除|回滾|回滚|執行測試|执行测试|跑測試|跑测试|執行 build|執行 test|run tests?|run build|build|test|implement|optimi[sz]e|rebuild|refactor|fix|edit|write|create|delete|remove|rollback)"#
    let targetFirstMutationAction =
      #"(?:修改|修好|修復|修复|改碼|改码|改(?:程式|程序|代碼|代码)|編輯|编辑|寫入|写入|新增|建立|創建|创建|實作|实现|優化|优化|重做|重構|重构|減碼|减码|補齊|补齐|隔離|隔离|刪除|删除|回滾|回滚|執行測試|执行测试|跑測試|跑测试|執行 build|執行 test|run tests?|run build|implement|optimi[sz]e|rebuild|refactor|fix|edit|write|create|delete|remove|rollback)"#
    let developmentTarget =
      #"(?:程式|程序|代碼|代码|檔案|文件|測試|测试|編譯|编译|建置|構建|构建|專案|项目|介面|界面|主題|主题|組件|组件|元件|動畫|动画|濾鏡|滤镜|底板|液態玻璃|液态玻璃|視覺效果|视觉效果|死碼|死码|repo|repository|workspace|source|file|code|test|build|git|gateway|route|runtime|swift|swiftui|xcode|package|app|ui|theme|component|animation|filter|view|island)"#
    if clause.range(
      of: #"^"# + optionalRequestLead + mutationAction
        + #".{0,48}"# + developmentTarget,
      options: .regularExpression) != nil
      || clause.range(
        of: #"^"# + explicitObjectRequestLead + developmentTarget
          + #".{0,48}"# + targetFirstMutationAction,
        options: .regularExpression) != nil
    {
      return .mutation
    }

    let readAction =
      #"(?:讀取|读取|讀|查看|檢查|检查|搜尋|搜索|查找|列出|掃描|扫描|read|inspect|check|search|grep|rg|list|pwd|git\s+status|git\s+diff)"#
    let readTarget =
      #"(?:檔案|文件|程式|程序|代碼|代码|內容|内容|入口|todo|readme|git|status|diff|workspace|repo|repository|source|file|code|swift|xcode|package|gateway|route|runtime|\.swift|\.md)"#
    if clause.range(
      of: #"^"# + optionalRequestLead + readAction
        + #".{0,64}"# + readTarget,
      options: .regularExpression) != nil
      || clause.range(
        of: #"^"# + explicitObjectRequestLead + readTarget
          + #".{0,64}"# + readAction,
        options: .regularExpression) != nil
    {
      return .readOnly
    }
    return .none
  }

  private static func isExplicitNativeToolChecklistLead(
    _ clause: String
  ) -> Bool {
    clause.range(
      of:
        #"^(?:(?:請|请|直接|務必|务必|幫我|帮我|替我|麻煩|麻烦|實際|实际|please)\s*)*(?:依序|逐項|逐项|one\s+by\s+one\s+)?(?:使用|用|呼叫|调用|use|invoke|call)\s+(?:tatwo\s*)?(?:(?:原生|內建|内建|built[\s-]*in)\s*)?(?:開發|开发|development\s+)?(?:工具|tools?)\s*[:：]?$"#,
      options: .regularExpression) != nil
  }

  private static func numberedNativeToolChecklistAccess(
    in clause: String
  ) -> TatwoNativeDevelopmentAccess {
    let prefix =
      #"^(?:[-*•]|\d{1,2}[.)、．]|[一二三四五六七八九十]+[、.)．])\s*"#
    if clause.range(
      of: prefix
        + #"(?:write_file|edit_file|run_command|build|test|rollback)\b"#,
      options: .regularExpression) != nil
    {
      return .mutation
    }
    if clause.range(
      of: prefix
        + #"(?:list_files|read_file|search|git_status|git_diff)\b"#,
      options: .regularExpression) != nil
    {
      return .readOnly
    }
    return .none
  }

  private static func clauseDeniesDevelopmentMutation(
    _ clause: String
  ) -> Bool {
    clause.range(
      of:
        #"^(?:(?:本輪|本轮|這輪|这轮|這一輪|这一轮|這次|这次|本次|現在|现在|先|請|请|請先|请先|務必|务必)\s*)*(?:(?:只讀|只读)\b|(?:禁止|不要|別|别|請勿|请勿|不准|不可|不得|不用|無需|无需|不需要).{0,12}(?:(?:改檔|改档)\b|(?:修改|編輯|编辑|寫入|写入|建立|新增|刪除|删除|執行|执行|測試|测试|build|test|edit|write|mutation).{0,16}(?:任何|所有|全部)?\s*(?:檔案|文件|程式|程序|代碼|代码|變更|变更|更改|repo|repository|workspace)))|^\s*\bread[\s-]*only\b|^(?:(?:for\s+this\s+turn|now|please)\s+)*(?:do\s+not|don['’]?t|never|must\s+not|without)\b.{0,24}\b(?:edit|write|modify|mutate|build|test|run)\b|^\s*\bno\s+edits?\b"#,
      options: .regularExpression) != nil
  }

  public static func plan(
    mode: TatwoChatCommandMode,
    route: TatwoChatRouteProfile,
    turn: String,
    workingDirectoryPath rawWorkingDirectoryPath: String,
    permissionPreset: TatwoPermissionPreset,
    interactionMode: TatwoChatInteractionMode = .standard,
    effort: TatwoCodexReasoningEffort,
    speedTier: TatwoModelSpeedTier? = nil,
    codexSessionID: String? = nil,
    claudeSessionID: String? = nil,
    grokSessionID: String? = nil,
    gatewayContinuationRequest: TatwoGatewayContinuationRequestV1? = nil,
    droppedPaths: [String] = [],
    additionalWritableDirectories: [String] = [],
    gatewayDirectScriptPath: String,
    toolHostRequirementTurn: String? = nil,
    computerHostTurnRoute: TatwoComputerHostTurnRoute? = nil,
    computerHostRunID: String? = nil,
    computerHostTurnID: String? = nil,
    computerHostMCPPath: String? = nil,
    computerHostAppMCPEndpoint: TatwoAppMCPEndpoint? = nil,
    appManagementMCPPath: String? = nil,
    appManagementMCPEndpoint: TatwoAppMCPEndpoint? = nil,
    perThreadAllowedMCPTools: [String] = [],
    computerHostContractID: String? = nil,
    computerHostLeaseID: String? = nil,
    coworkLogFilePath: String? = nil,
    skipGitRepoCheck: Bool = false,
    nativeDevelopmentRequested: Bool = false,
    nativeDevelopmentAccess: TatwoNativeDevelopmentAccess = .none,
    preferNativeSubscription: Bool? = nil,
    codexHomePath: String? = nil,
    bundleURL: URL = Bundle.main.bundleURL,
    environment: [String: String]? = nil,
    isExecutableFile: ((String) -> Bool)? = nil
  ) -> TatwoChatCommandPlan {
    let workingDirectoryPath = rawWorkingDirectoryPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? FileManager.default.currentDirectoryPath
      : rawWorkingDirectoryPath
    let writableDirectories = additionalWritableDirectories.reduce(into: [String]()) {
      result, rawPath in
      let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
      guard path.hasPrefix("/") else { return }
      let standardized = URL(
        fileURLWithPath: path,
        isDirectory: true
      ).standardizedFileURL.path
      if !result.contains(standardized) {
        result.append(standardized)
      }
    }

    // Chat turns run as a child of this app's LSUIElement accessory process,
    // which macOS treats as perpetually backgrounded (never frontmost). That
    // background classification is inherited by freshly spawned children at
    // launch, which throttles their scheduling and networking QoS enough to
    // stall a `codex exec`/`claude` turn indefinitely waiting on the model
    // API even though the identical argv/env returns in seconds from a
    // foreground terminal. Only the interactive Chat tab needs the runner to
    // request foreground-equivalent scheduling for its one-shot process.
    let requiresForegroundScheduling = mode == .chat

    if route.runtimeAdapter == .unavailable {
      return TatwoChatCommandPlan(
        routeID: route.id,
        engine: route.engine,
        runtimeAdapter: route.runtimeAdapter,
        canonicalModelSlug: route.canonicalModelSlug,
        executable: "/usr/bin/false",
        arguments: [],
        workingDirectoryPath: workingDirectoryPath,
        expectsJSON: false,
        capturesSessionID: false,
        standardInputFromDevNull: true,
        requiresForegroundScheduling: false)
    }

    let prompt: String
    let logFilePath: String?
    let standardInputFromDevNull: Bool
    switch mode {
    case .chat:
      prompt = turn
      logFilePath = nil
      standardInputFromDevNull = true
    case .cowork:
      prompt = """
      TATWO Ultrawork job. Work only inside the requested workspace unless the user explicitly says otherwise. Stream concise progress and final status.

      Workspace: \(workingDirectoryPath)

      Job:
      \(turn)
      """
      logFilePath = coworkLogFilePath
      standardInputFromDevNull = true
    case .cli:
      return TatwoChatCommandPlan(
        routeID: route.id,
        engine: route.engine,
        runtimeAdapter: route.runtimeAdapter,
        canonicalModelSlug: route.canonicalModelSlug,
        executable: "/bin/zsh",
        arguments: ["-lc", turn],
        workingDirectoryPath: workingDirectoryPath,
        expectsJSON: false,
        capturesSessionID: false,
        standardInputFromDevNull: true,
        requiresForegroundScheduling: requiresForegroundScheduling)
    }

    let nativeEffort = route.nativeReasoningEffort(for: effort)
    let nativeSpeedTier = mode == .chat ? route.nativeSpeedTier(for: speedTier) : nil

    let computerHostRequirement = toolHostRequirementTurn ?? turn
    let resolvedComputerHostTurnRoute =
      computerHostTurnRoute
      ?? TatwoComputerHostTurnRoutingPolicy.select(
        userRequestedComputerUse: requiresTatwoComputerHost(
          for: computerHostRequirement),
        isChatMode: mode == .chat,
        isPlanMode: interactionMode == .plan,
        route: route)
    let requiresClaudeComputerHostIntentBridge =
      mode == .chat
      && route.engine == .claude
      && resolvedComputerHostTurnRoute == .mcp
    let chatImagePaths = mode == .chat ? droppedPaths.filter(isLikelyImagePath) : []
    var runtimeRouteDecision = runtimeRouteDecisionForTurn(
      route: route,
      interactionMode: interactionMode,
      hasImageAttachments: !chatImagePaths.isEmpty,
      requiresTatwoComputerHost: requiresClaudeComputerHostIntentBridge,
      nativeDevelopmentAccess: nativeDevelopmentAccess,
      preferNativeSubscription: preferNativeSubscription)
    var resolvedRuntimeAdapter = runtimeRouteDecision.adapter
    var resolvedDevelopmentExecutable: String?
    let currentTurnAuthority = gatewayCurrentTurnAuthorityBinding(
      runID: computerHostRunID,
      turnID: computerHostTurnID,
      currentVisibleTurn: toolHostRequirementTurn)
    // The current-turn authority fence belongs to the requested capability,
    // not to the selected transport. Native CLI routes must not bypass the
    // same fail-closed check that protects gatewayDirect.
    if mode == .chat,
       (toolHostRequirementTurn != nil
        || resolvedComputerHostTurnRoute != .none),
       currentTurnAuthority == nil
    {
      return TatwoChatCommandPlan(
        routeID: route.id,
        engine: route.engine,
        runtimeAdapter: .unavailable,
        canonicalModelSlug: route.canonicalModelSlug,
        executable: "/usr/bin/false",
        arguments: [],
        workingDirectoryPath: workingDirectoryPath,
        expectsJSON: false,
        capturesSessionID: false,
        standardInputFromDevNull: true,
        requiresForegroundScheduling: false)
    }
    if mode == .chat {
      // No injected probe means no filesystem access. Production explicitly
      // injects its bundle, environment and executable probe; pure planner
      // calls remain deterministic and can only downgrade.
      let resolvedEnvironment = environment ?? [:]
      let executableProbe = isExecutableFile ?? { _ in false }
      let allowsPATHFallback = environment != nil && isExecutableFile != nil
      let path = allowsPATHFallback ? (resolvedEnvironment["PATH"] ?? "") : ""
      switch resolvedRuntimeAdapter {
      case .codexExec:
        let executable = bundledExecutablePath(
          for: "codex",
          bundleURL: bundleURL,
          isExecutableFile: executableProbe)
          ?? resolvedExecutablePath(
            for: "codex",
            pathEnvironmentValue: path,
            isExecutableFile: executableProbe)
        if executable == "codex" {
          runtimeRouteDecision = .init(
            adapter: .unavailable,
            fallbackReason: .codexExecutableUnavailable)
        } else {
          resolvedDevelopmentExecutable = executable
        }
      case .claudeCLI:
        let executable = bundledExecutablePath(
          for: "claude",
          bundleURL: bundleURL,
          isExecutableFile: executableProbe)
          ?? resolvedExecutablePath(
            for: "claude",
            pathEnvironmentValue: path,
            isExecutableFile: executableProbe)
        if executable == "claude" {
          runtimeRouteDecision = .init(
            adapter: .unavailable,
            fallbackReason: .claudeExecutableUnavailable)
        } else {
          resolvedDevelopmentExecutable = executable
        }
      case .grokCLI:
        if let executable = grokExecutablePath(
          bundleURL: bundleURL,
          pathEnvironmentValue: path,
          isExecutableFile: executableProbe)
        {
          resolvedDevelopmentExecutable = executable
        } else {
          runtimeRouteDecision = .init(
            adapter: .unavailable,
            fallbackReason: .grokExecutableUnavailable)
        }
      case .minimaxDirect, .gatewayDirect, .nativeAgent, .unavailable:
        break
      }
      resolvedRuntimeAdapter = runtimeRouteDecision.adapter
    }
    let useNativeClaudeRescue = resolvedRuntimeAdapter == .claudeCLI
      && route.engine == .claude
    let imageTransport = route.imageTransportCapability(
      interactionMode: interactionMode,
      requiresTatwoComputerHost: false)
    if !chatImagePaths.isEmpty, imageTransport == .none {
      return TatwoChatCommandPlan(
        routeID: route.id,
        engine: route.engine,
        runtimeAdapter: .unavailable,
        canonicalModelSlug: route.canonicalModelSlug,
        executable: "/usr/bin/false",
        arguments: [],
        workingDirectoryPath: workingDirectoryPath,
        expectsJSON: false,
        capturesSessionID: false,
        standardInputFromDevNull: true,
        requiresForegroundScheduling: false)
    }

    // 2026-08-23 fable5 依使用者 2026-08-20 D2 裁決（「開發能力預設常開、由權限
    // 檔位管制」）拆除硬擋：意圖分類器判定的日常開發請求在沒有 Goal 契約時，
    // 不再 fail-closed 假死（原症狀＝「跑 curl」一句話整輪 dev_runtime_unavailable、
    // 錯誤訊息還誤導使用者重裝 App）。改降級走一般 transport（claudeCLI/codex），
    // 寫入權限由 permissionPreset 工具政策把關；受契約治理的 nativeAgent runtime
    // 僅在 access 已授權時由 runtimeAdapterForTurn 選中，不受此變更影響。

    if resolvedRuntimeAdapter == .nativeAgent {
      return TatwoChatCommandPlan(
        routeID: route.id,
        engine: route.engine,
        runtimeAdapter: .nativeAgent,
        canonicalModelSlug: route.canonicalModelSlug,
        executable: "/usr/bin/false",
        arguments: [],
        workingDirectoryPath: workingDirectoryPath,
        expectsJSON: false,
        capturesSessionID: false,
        standardInputFromDevNull: true,
        requiresForegroundScheduling: false,
        nativeDevelopmentAccess: nativeDevelopmentAccess)
    }

    if resolvedRuntimeAdapter == .minimaxDirect {
      return TatwoChatCommandPlan(
        routeID: route.id,
        engine: route.engine,
        runtimeAdapter: .minimaxDirect,
        canonicalModelSlug: route.canonicalModelSlug,
        executable: "/usr/bin/false",
        arguments: [],
        workingDirectoryPath: workingDirectoryPath,
        expectsJSON: false,
        capturesSessionID: false,
        standardInputFromDevNull: true,
        requiresForegroundScheduling: false)
    }

    if resolvedRuntimeAdapter == .unavailable {
      return TatwoChatCommandPlan(
        routeID: route.id,
        engine: route.engine,
        runtimeAdapter: .unavailable,
        canonicalModelSlug: route.canonicalModelSlug,
        executable: "/usr/bin/false",
        arguments: [],
        workingDirectoryPath: workingDirectoryPath,
        expectsJSON: false,
        capturesSessionID: false,
        standardInputFromDevNull: true,
        requiresForegroundScheduling: false,
        runtimeFallbackReason: runtimeRouteDecision.fallbackReason)
    }

    // Deprecated D5 compatibility branch. Production route decisions above
    // no longer select gatewayDirect; retain construction for historical
    // fixtures and receipt decoding only.
    if resolvedRuntimeAdapter == .gatewayDirect {
      guard let currentTurnAuthority else {
        return TatwoChatCommandPlan(
          routeID: route.id,
          engine: route.engine,
          runtimeAdapter: .unavailable,
          canonicalModelSlug: route.canonicalModelSlug,
          executable: "/usr/bin/false",
          arguments: [],
          workingDirectoryPath: workingDirectoryPath,
          expectsJSON: false,
          capturesSessionID: false,
          standardInputFromDevNull: true,
          requiresForegroundScheduling: false)
      }
      guard let promptFile = createGatewayPromptFile(prompt) else {
        return TatwoChatCommandPlan(
          routeID: route.id,
          engine: route.engine,
          runtimeAdapter: .unavailable,
          canonicalModelSlug: route.canonicalModelSlug,
          executable: "/usr/bin/false",
          arguments: [],
          workingDirectoryPath: workingDirectoryPath,
          expectsJSON: false,
          capturesSessionID: false,
          standardInputFromDevNull: true,
          requiresForegroundScheduling: false)
      }
      let continuationFile: GatewayContinuationFile?
      if let gatewayContinuationRequest {
        guard let created = createGatewayContinuationFile(
          gatewayContinuationRequest)
        else {
          return TatwoChatCommandPlan(
            routeID: route.id,
            engine: route.engine,
            runtimeAdapter: .unavailable,
            canonicalModelSlug: route.canonicalModelSlug,
            executable: "/usr/bin/false",
            arguments: [],
            workingDirectoryPath: workingDirectoryPath,
            expectsJSON: false,
            capturesSessionID: false,
            standardInputFromDevNull: true,
            requiresForegroundScheduling: false)
        }
        continuationFile = created
      } else {
        continuationFile = nil
      }
      var arguments = [
        gatewayDirectScriptPath,
        "--model", route.canonicalModelSlug,
        "--timeout-ms", String(gatewayDirectInactivityTimeoutMilliseconds),
        // The App already classified the exact visible current turn. Carry
        // that bounded decision beside the flattened same-thread prompt so
        // the gateway never re-authorizes Computer Use from quoted history.
        "--computer-host-route", resolvedComputerHostTurnRoute.rawValue,
        "--run-id", currentTurnAuthority.runID,
        "--turn-id", currentTurnAuthority.turnID,
        "--current-turn-sha256", currentTurnAuthority.currentVisibleTurnSHA256,
        "--current-turn-bytes", String(currentTurnAuthority.currentVisibleTurnUTF8Bytes)
      ]
      if let nativeEffort {
        arguments += ["--reasoning-effort", nativeEffort.gatewayReasoningValue]
      }
      if let nativeSpeedTier {
        arguments += ["--service-tier", nativeSpeedTier.serviceTierValue]
      }
      // The App's accumulated same-thread context can exceed macOS argv
      // limits before the child starts. Keep prompt bytes out of argv/env:
      // create a mode-0600, O_EXCL file and pass only bounded metadata. The
      // adapter opens it with O_NOFOLLOW, verifies byte count + SHA-256, then
      // unlinks it immediately after reading.
      arguments += [
        "--prompt-file", promptFile.path,
        "--prompt-sha256", promptFile.sha256,
        "--prompt-bytes", String(promptFile.utf8Bytes),
        "--delete-prompt-file"
      ]
      if let continuationFile {
        arguments += [
          "--continuation-file", continuationFile.path,
          "--continuation-sha256", continuationFile.sha256,
          "--continuation-bytes", String(continuationFile.utf8Bytes),
          "--delete-continuation-file"
        ]
      }
      if mode == .chat, imageTransport == .directGatewayImage {
        arguments += chatImagePaths.flatMap { ["--image", $0] }
      }
      return TatwoChatCommandPlan(
        routeID: route.id,
        engine: route.engine,
        runtimeAdapter: .gatewayDirect,
        canonicalModelSlug: route.canonicalModelSlug,
        executable: "node",
        arguments: arguments,
        workingDirectoryPath: workingDirectoryPath,
        expectsJSON: true,
        capturesSessionID: false,
        logFilePath: logFilePath,
        standardInputFromDevNull: standardInputFromDevNull,
        requiresForegroundScheduling: requiresForegroundScheduling,
        runtimeFallbackReason: runtimeRouteDecision.fallbackReason,
        gatewayContinuationRequest: gatewayContinuationRequest,
        ownedTemporaryFiles: [promptFile.ownership]
          + (continuationFile.map { [$0.ownership] } ?? []))
    }

    if resolvedRuntimeAdapter == .grokCLI {
      let isolatedHome = grokIsolatedHomePath(environment: environment ?? [:])
      let resumeArgs = (
        mode == .chat
          ? sanitizedGrokResumeSessionID(grokSessionID)
          : nil
      ).map { ["-r", $0] } ?? []
      let grokPermissionArgs = interactionMode == .plan
        ? ["--permission-mode", "plan"]
        : permissionPreset.grokArguments
      let grokPlanToolArgs = interactionMode == .plan
        ? ["--tools", "Read,Grep,Glob"]
        : []
      let grokModeArgs = interactionMode == .plan
        ? ["--rules", TatwoChatInteractionMode.claudePlanSystemPrompt]
        : [
          "--no-plan",
          "--rules",
          "For actionable requests, complete the requested work and verification in this turn. Do not stop after announcing a plan.",
        ]
      let grokPromptArgs: [String]
      if mode == .chat,
        imageTransport == .grokPromptJSONImage,
        !chatImagePaths.isEmpty
      {
        guard let promptJSON = grokPromptJSON(
          prompt: prompt,
          imagePaths: chatImagePaths)
        else {
          return TatwoChatCommandPlan(
            routeID: route.id,
            engine: route.engine,
            runtimeAdapter: .unavailable,
            canonicalModelSlug: route.canonicalModelSlug,
            executable: "/usr/bin/false",
            arguments: [],
            workingDirectoryPath: workingDirectoryPath,
            expectsJSON: false,
            capturesSessionID: false,
            standardInputFromDevNull: true,
            requiresForegroundScheduling: false)
        }
        grokPromptArgs = ["--prompt-json", promptJSON]
      } else {
        grokPromptArgs = ["-p", prompt]
      }
      return TatwoChatCommandPlan(
        routeID: route.id,
        engine: route.engine,
        runtimeAdapter: .grokCLI,
        canonicalModelSlug: route.canonicalModelSlug,
        executable: resolvedDevelopmentExecutable ?? "grok",
        arguments: [
          "--cwd", workingDirectoryPath,
        ]
          + grokPermissionArgs
          + grokPlanToolArgs
          + [
            "--output-format", "streaming-json",
            "--no-memory",
            "--no-subagents",
            "--max-turns", "32",
          ]
          + grokModeArgs
          + resumeArgs
          + grokPromptArgs,
        workingDirectoryPath: workingDirectoryPath,
        expectsJSON: true,
        capturesSessionID: true,
        logFilePath: logFilePath,
        standardInputFromDevNull: standardInputFromDevNull,
        requiresForegroundScheduling: requiresForegroundScheduling,
        environmentOverrides: [
          "HOME": isolatedHome,
          "GROK_HOME": URL(
            fileURLWithPath: isolatedHome,
            isDirectory: true)
            .appendingPathComponent(".grok", isDirectory: true).path,
          "XDG_CONFIG_HOME": URL(
            fileURLWithPath: isolatedHome,
            isDirectory: true)
            .appendingPathComponent(".config", isDirectory: true).path,
          "XDG_CACHE_HOME": URL(
            fileURLWithPath: isolatedHome,
            isDirectory: true)
            .appendingPathComponent(".cache", isDirectory: true).path,
        ])
    }

    switch route.engine {
    case .codex:
      let codexResumeSessionID = mode == .chat ? sanitizedCodexResumeSessionID(codexSessionID) : nil
      let cdFlag = mode == .cowork ? "--cd" : "-C"
      // 2026-08-23 工程 D 補洞：OS 管理 MCP 也掛 codex 路由（sol 初版只掛
      // claude——使用者實測 5.5/sol 回「工具清單沒有 loops/分頁控制器」）。
      let appManagementCodexArgs: [String]
      if mode == .chat,
         let appManagementMCPPath,
         let appManagementURL = appManagementMCPEndpoint?.url.absoluteString {
        appManagementCodexArgs = [
          "-c", "mcp_servers.tatwo-app.command=\"node\"",
          "-c", "mcp_servers.tatwo-app.args=[\"\(appManagementMCPPath)\"]",
          "-c", "mcp_servers.tatwo-app.env.TATWO_APP_MCP_URL=\"\(appManagementURL)\"",
          // 2026-08-23 headless 實測：workspace-write 下 codex 把 MCP 呼叫
          // 掛進核准流程，exec 無 TTY 一律 "user cancelled MCP tool call"；
          // approval_policy=never / auto / writes 都救不了，只有
          // default_tools_approval_mode="approve"（預先核准）真的放行。
          "-c", "mcp_servers.tatwo-app.default_tools_approval_mode=\"approve\"",
        ]
      } else {
        appManagementCodexArgs = []
      }
      // 2026-09-02 exec arena T6: codex's workspace-write sandbox keeps
      // `.git` read-only, so `git commit` in the user's own project failed
      // (index.lock). Declaring the workdir's .git as a writable root lifts
      // that for the "代我核准" tier only; askFirst stays read-only.
      let gitWritableRootArgs: [String] =
        mode == .chat
          && interactionMode == .standard
          && permissionPreset.codexSandboxMode == .workspaceWrite
          ? [
            "-c",
            "sandbox_workspace_write.writable_roots=[\""
              + Self.tomlBasicStringEscaped(workingDirectoryPath + "/.git")
              + "\"]",
          ]
          : []
      var controlArgs: [String] = [cdFlag, workingDirectoryPath]
      controlArgs += interactionMode.codexArguments(fallback: permissionPreset)
      if interactionMode == .standard && permissionPreset.codexSandboxMode == .workspaceWrite {
        controlArgs += writableDirectories.flatMap { ["--add-dir", $0] }
      }
      controlArgs += gitWritableRootArgs
      controlArgs += route.modelArgument.map { ["-m", $0] } ?? []
      controlArgs += nativeEffort?.codexArguments ?? []
      controlArgs += nativeSpeedTier?.codexArguments ?? []
      controlArgs += appManagementCodexArgs
      let repoTrustArgs = (mode == .chat && skipGitRepoCheck) ? ["--skip-git-repo-check"] : []
      // Chat turns are one-shot JSONL exec calls with no need for codex's
      // interactive shell-alias snapshot machinery. That subsystem forks a
      // login zsh to capture env/aliases before the turn can proceed; under
      // this app's LSUIElement process tree that fork has been observed to
      // log "Snapshot command timed out for zsh" and then leave the turn
      // idle forever (0 CPU, no stdout/stderr) even though the identical
      // argv finishes in seconds from a terminal. Disabling the feature
      // sidesteps the hang instead of guessing at its internal cause.
      //
      // B5: after disabling the shell-snapshot machinery, GUI-spawned Chat
      // turns still stalled with zero stdout. A live terminal repro of the
      // exact app argv/env succeeded every time, and its stderr always ran
      // through codex's plugin/skill marketplace manifest sync (multiple
      // `codex_core_plugins`/`codex_core_skills` warnings) before the first
      // JSON event. The failing GUI-spawned runs' stderr consistently cut
      // off partway through that same plugin/skill sync phase and never
      // reached the first stdout event. A one-shot "reply only" Chat turn
      // has no use for marketplace skill/plugin routing, so `--disable
      // plugins` removes that phase entirely (confirmed via terminal repro:
      // turn completes in ~3s instead of ~5-11s, ~5k fewer input tokens,
      // and no plugin/skill manifest warnings at all). This trades away
      // skill/plugin invocation from Chat turns specifically; cowork/cli
      // modes are unaffected.
      let shellSnapshotDisableArgs = mode == .chat
        ? [
            "--disable", "shell_snapshot",
            "--disable", "shell_zsh_fork",
            "--disable", "unified_exec_zsh_fork",
            "--disable", "plugins"
          ]
        : []
      let imageArgs =
        mode == .chat && imageTransport == .codexExecImage
        ? chatImagePaths.flatMap { ["--image", $0] }
        : []
      var args: [String] = ["exec"]
      args += controlArgs
      args += shellSnapshotDisableArgs
      args += repoTrustArgs
      let codexPromptArgument = mode == .chat ? "-" : prompt
      let codexStandardInput = mode == .chat ? prompt : nil
      if let codexResumeSessionID {
        args += ["resume", "--json"]
        args += imageArgs
        args += [codexResumeSessionID, codexPromptArgument]
      } else {
        // Keep the prompt before variadic image arguments on initial turns.
        args += ["--json", codexPromptArgument]
        args += imageArgs
      }
      return TatwoChatCommandPlan(
        routeID: route.id,
        engine: route.engine,
        runtimeAdapter: route.runtimeAdapter,
        canonicalModelSlug: route.canonicalModelSlug,
        executable: resolvedDevelopmentExecutable ?? "codex",
        arguments: args,
        workingDirectoryPath: workingDirectoryPath,
        expectsJSON: true,
        capturesSessionID: true,
        logFilePath: logFilePath,
        standardInputFromDevNull:
          mode == .chat ? false : standardInputFromDevNull,
        standardInputUTF8: codexStandardInput,
        requiresForegroundScheduling: requiresForegroundScheduling,
        environmentOverrides: codexHomePath.map {
          ["HOME": $0, "CODEX_HOME": $0]
        } ?? [:])
    case .claude:
      if requiresClaudeComputerHostIntentBridge,
         (
          computerHostMCPPath == nil
            || computerHostAppMCPEndpoint == nil
            || computerHostContractID == nil
            || computerHostLeaseID == nil
         )
      {
        return TatwoChatCommandPlan(
          routeID: route.id,
          engine: route.engine,
          runtimeAdapter: .unavailable,
          canonicalModelSlug: route.canonicalModelSlug,
          executable: "/usr/bin/false",
          arguments: [],
          workingDirectoryPath: workingDirectoryPath,
          expectsJSON: false,
          capturesSessionID: false,
          standardInputFromDevNull: true,
          requiresForegroundScheduling: false)
      }
      let resumeArgs = (
        mode == .chat && !requiresClaudeComputerHostIntentBridge
          ? sanitizedClaudeResumeSessionID(claudeSessionID)
          : nil
      ).map { ["--resume", $0] } ?? []
      let imagePaths = imageTransport == .claudeReadRescue ? chatImagePaths : []
      let imageDirectories = imagePaths.reduce(into: [String]()) { result, imagePath in
        let directory = URL(fileURLWithPath: imagePath).deletingLastPathComponent().standardizedFileURL.path
        if !result.contains(directory) {
          result.append(directory)
        }
      }
      let imageAccessArgs = imagePaths.isEmpty
        ? []
        : ["--add-dir"] + imageDirectories + ["--"]
      let taskOutputAccessArgs =
        interactionMode == .standard
          && (permissionPreset == .approveForMe || permissionPreset == .fullAccess)
        ? writableDirectories.flatMap { ["--add-dir", $0] }
        : []
      let resolvedComputerHostMCPConfig = claudeMCPConfig(
        appManagementScriptPath: appManagementMCPPath,
        appManagementURL: appManagementMCPEndpoint?.url.absoluteString,
        computerScriptPath: requiresClaudeComputerHostIntentBridge ? computerHostMCPPath : nil,
        computerURL: requiresClaudeComputerHostIntentBridge
          ? computerHostAppMCPEndpoint?.url.absoluteString : nil,
        contractID: computerHostContractID,
        leaseID: computerHostLeaseID,
        runID: computerHostRunID,
        workspaceRoot: workingDirectoryPath)
      let claudePrompt = requiresClaudeComputerHostIntentBridge
        ? computerHostRequirement
        : prompt
      let imageAwarePrompt = imagePaths.isEmpty
        ? claudePrompt
        : claudePrompt + """


          [Claude image attachments — inspect each path with the Read tool]
          \(imagePaths.map { "- \($0)" }.joined(separator: "\n"))
          """
      // 2026-08-23 fable5 驗收修正：普通 chat turn 不得是空工具集（sol 初版
      // 把「必須明示」實作成明示空集＝比修之前更斷手斷腳）。
      // 普通 chat＝完整開發工具集（codex 對齊，SPEC 工程 C）；授權集跟
      // permissionPreset 走：代我核准/全放行→全自動、其餘→唯讀自動+寫入提示。
      let fullDevTools = [
        "Bash", "Read", "Write", "Edit", "Grep", "Glob",
        "WebFetch", "WebSearch", "ToolSearch",
      ]
      let autoApproveWrites =
        permissionPreset == .fullAccess || permissionPreset == .approveForMe
      let explicitTools: [String] = requiresClaudeComputerHostIntentBridge
        ? ["ToolSearch", "Read", "Grep", "Glob"]
        : interactionMode == .plan
          ? ["Read", "Grep", "Glob"]
          : fullDevTools
      let explicitlyAllowedTools: [String] = requiresClaudeComputerHostIntentBridge
        ? ["ToolSearch", "Read", "Grep", "Glob", "mcp__tatwo-computer__tatwo_computer"]
        : interactionMode == .plan
          ? ["Read", "Grep", "Glob"]
          : autoApproveWrites
            ? fullDevTools
            : ["Read", "Grep", "Glob", "WebFetch", "WebSearch", "ToolSearch"]
      let appMCPAllowedTools =
        appManagementMCPPath != nil && appManagementMCPEndpoint != nil
        ? TatwoChatAppMCPToolCatalog.allowedTools(
          permissionPreset: permissionPreset,
          perThreadAllowlist: perThreadAllowedMCPTools)
        : []
      // 2026-08-23 工程 B 補完：per-thread allowlist 也承載內建工具
      //（「先問我」檔位下一鍵放行 Write/Bash 等），mcp__ 以外的名字直接
      // 進 --allowedTools（僅限本 turn 已明示的 fullDevTools 範圍）。
      let perThreadBuiltinAllowed = perThreadAllowedMCPTools.filter {
        !$0.hasPrefix("mcp__") && fullDevTools.contains($0)
          && !explicitlyAllowedTools.contains($0)
      }
      let executable = resolvedDevelopmentExecutable ?? "claude"
      let executableURL = executable.hasPrefix("/")
        ? URL(fileURLWithPath: executable)
        : URL(fileURLWithPath: "/usr/bin/env")
      let authority = ClaudeSpawnAuthority(
        executableURL: executableURL,
        environment: environment ?? ProcessInfo.processInfo.environment)
      guard let authorityPlan = try? authority.plan(ClaudeSpawnRequest(
        purpose: requiresClaudeComputerHostIntentBridge ? .computerHostBridge : .chatTurn,
        canonicalModelSlug: route.canonicalModelSlug,
        effort: nativeEffort?.rawValue,
        toolPolicy: ClaudeSpawnToolPolicy(
          tools: explicitTools,
          allowedTools: explicitlyAllowedTools + appMCPAllowedTools
            + perThreadBuiltinAllowed),
        networkPolicy: .allowed,
        workingDirectory: URL(fileURLWithPath: workingDirectoryPath, isDirectory: true),
        extraMCPConfig: resolvedComputerHostMCPConfig,
        additionalArguments: ["-p", "--output-format", "stream-json", "--verbose"]
          + interactionMode.claudeArguments(fallback: permissionPreset)
          + resumeArgs
          + taskOutputAccessArgs
          + imageAccessArgs
          + [imageAwarePrompt]))
      else {
        return TatwoChatCommandPlan(
          routeID: route.id,
          engine: route.engine,
          runtimeAdapter: .unavailable,
          canonicalModelSlug: route.canonicalModelSlug,
          executable: "/usr/bin/false",
          arguments: [],
          workingDirectoryPath: workingDirectoryPath,
          expectsJSON: false,
          capturesSessionID: false,
          standardInputFromDevNull: true,
          requiresForegroundScheduling: false)
      }
      return TatwoChatCommandPlan(
        routeID: route.id,
        engine: route.engine,
        runtimeAdapter: resolvedRuntimeAdapter,
        canonicalModelSlug: route.canonicalModelSlug,
        executable: executable,
        arguments: authorityPlan.arguments,
        workingDirectoryPath: workingDirectoryPath,
        expectsJSON: true,
        capturesSessionID: true,
        logFilePath: logFilePath,
        standardInputFromDevNull: standardInputFromDevNull,
        requiresForegroundScheduling: requiresForegroundScheduling,
        environmentOverrides: authorityPlan.environment)
    }
  }
}
