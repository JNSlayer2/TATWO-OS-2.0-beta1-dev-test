import Foundation
import XCTest
@testable import TatwoUltraworkCore

final class TatwoNativeChatIntegrationTests: XCTestCase {
  func testCurrentTurnDevelopmentAccessIgnoresScenarioNamesAndHonorsToolDenials() {
    XCTAssertEqual(
      TatwoChatCommandPlanner.nativeDevelopmentAccess(
        currentVisibleTurn:
          "禁止改檔；請實際使用 read/search/shell 完成 pwd、git status，並讀取 GoalAuthorityTransaction.swift。",
        mode: .chat,
        interactionMode: .standard,
        scenarioPhase: .plan,
        contractStatus: .planned),
      .readOnly)

    XCTAssertEqual(
      TatwoChatCommandPlanner.nativeDevelopmentAccess(
        currentVisibleTurn: "請修改路由、執行測試並回傳 git diff。",
        mode: .chat,
        interactionMode: .standard,
        scenarioPhase: .loops,
        contractStatus: .running),
      .mutation)

    XCTAssertEqual(
      TatwoChatCommandPlanner.nativeDevelopmentAccess(
        currentVisibleTurn: "只解釋這個設計，不要使用任何工具。",
        mode: .chat,
        interactionMode: .standard,
        scenarioPhase: .loops,
        contractStatus: .running),
      .none)

    XCTAssertEqual(
      TatwoChatCommandPlanner.nativeDevelopmentAccess(
        currentVisibleTurn:
          "不要使用工具；但是現在請讀取 README 並搜尋 TODO。",
        mode: .chat,
        interactionMode: .standard,
        scenarioPhase: .loops,
        contractStatus: .running),
      .readOnly)
  }

  func testExactNativeToolNamesAuthorizeTheNativeRuntime() {
    let fullE2EPrompt =
      "實際使用 TATWO 內建 read_file 讀取 Packages/TatwoUltraworkCore/Tests/TatwoUltraworkCoreTests/TatwoNativeDevelopmentToolTests.swift、使用 git_diff 查看目前工作樹差異、使用 run_command 執行 swift test --jobs 2 --filter TatwoNativeDevelopmentToolTests。最後逐項回報工具結果、exit code、測試數，並附 exact gpt-5.6-sol、High、ChatGPT Pro 訂閱、zero fallback、無 API Key、bundle runtime path 的可驗證 attestation。禁止猜測。"

    let planDecision = TatwoChatCommandPlanner.nativeDevelopmentDecision(
      currentVisibleTurn: fullE2EPrompt,
      mode: .chat,
      interactionMode: .plan,
      scenarioPhase: .plan,
      contractStatus: .planned)
    XCTAssertTrue(planDecision.requested)
    XCTAssertEqual(planDecision.access, .readOnly)

    let loopsDecision = TatwoChatCommandPlanner.nativeDevelopmentDecision(
      currentVisibleTurn: fullE2EPrompt,
      mode: .chat,
      interactionMode: .standard,
      scenarioPhase: .loops,
      contractStatus: .running)
    XCTAssertTrue(loopsDecision.requested)
    XCTAssertEqual(loopsDecision.access, .mutation)

    for readOnlyPrompt in [
      "實際使用 TATWO 內建 list_files 查看專案。",
      "使用 read_file 讀取 README.md。",
      "使用 search 搜尋 TODO。",
      "使用 git_status 查看目前狀態。",
      "使用 git_diff 查看目前工作樹差異。",
    ] {
      XCTAssertEqual(
        TatwoChatCommandPlanner.nativeDevelopmentAccess(
          currentVisibleTurn: readOnlyPrompt,
          mode: .chat,
          interactionMode: .standard,
          scenarioPhase: .loops,
          contractStatus: .running),
        .readOnly,
        readOnlyPrompt)
    }

    for mutationPrompt in [
      "使用 write_file 寫入測試檔。",
      "使用 edit_file 修改程式。",
      "使用 run_command 執行 swift test。",
      "使用 build 建置專案。",
      "使用 test 執行測試。",
      "使用 rollback 回滾變更。",
    ] {
      XCTAssertEqual(
        TatwoChatCommandPlanner.nativeDevelopmentAccess(
          currentVisibleTurn: mutationPrompt,
          mode: .chat,
          interactionMode: .standard,
          scenarioPhase: .loops,
          contractStatus: .running),
        .mutation,
        mutationPrompt)
    }
  }

  func testStructuredUIRefactorGoalIsRecognizedAsNativeDevelopmentWithoutToolNameIncantations() {
    let objective = """
      黑塊修好後，為整個 Tatwo Island 進行減碼，避免死碼越堆越多，低耗能、高視覺效果、縮展順暢。
      Island 完成後，從 OS App 進行 Tatwo OS 整體主題風格優化；把 Fable 5 紀念風格與極光風格隔離，補齊極光風格缺失的 UI 組件，用 Island 的液態玻璃重做極光主題，底板也要有液態效果。
      Fable 5 紀念風格與 Ultrawork 漸變拉條禁止變動。
      """

    let decision = TatwoChatCommandPlanner.nativeDevelopmentDecision(
      currentVisibleTurn: objective,
      mode: .chat,
      interactionMode: .plan,
      scenarioPhase: .plan,
      contractStatus: .planned)

    XCTAssertTrue(decision.requested)
    XCTAssertEqual(decision.access, .readOnly)
    XCTAssertEqual(
      TatwoChatCommandPlanner.nativeDevelopmentAccess(
        currentVisibleTurn: "我喜歡目前的極光 UI 與液態玻璃風格。",
        mode: .chat,
        interactionMode: .standard,
        scenarioPhase: .loops,
        contractStatus: .running),
      .none)
  }

  func testOnlyRedoIslandLiquidGlassGoalIsRecognizedAsNativeDevelopment() {
    let objective =
      "只重做 TATWO Island 的液態玻璃底板濾鏡，對照本機 macOS 27 原生 Liquid Glass 逐輪截圖校正，直到材質、透光、模糊、折射、高光與收合動畫一致。保留現有 Island 互動、Ultrawork 漸變拉條與 Fable 5 紀念主題，不做其他改動。"

    let decision = TatwoChatCommandPlanner.nativeDevelopmentDecision(
      currentVisibleTurn: objective,
      mode: .chat,
      interactionMode: .plan,
      scenarioPhase: .plan,
      contractStatus: .planned)

    XCTAssertTrue(decision.requested)
    XCTAssertEqual(decision.access, .readOnly)
  }

  func testNumberedNativeToolChecklistAuthorizesNativeRuntime() throws {
    let prompt = """
      只延續這個既有 Goal／contract，不建立新 Goal。現在只做 Sol 階段。

      請實際依序使用 TATWO 原生工具：
      1. read_file 讀取 Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/ChatPageModel.swift。
      2. git_diff 檢查目前變更。
      3. run_command 執行 pwd、git status --short 與針對性測試。

      禁止 API／API Key。三項工具未全部成功前，不開始 Opus。
      """
    let decision = TatwoChatCommandPlanner.nativeDevelopmentDecision(
      currentVisibleTurn: prompt,
      mode: .chat,
      interactionMode: .standard,
      scenarioPhase: .plan,
      contractStatus: .planned)

    XCTAssertTrue(decision.requested)
    XCTAssertEqual(decision.access, .readOnly)
    let route = try XCTUnwrap(
      TatwoChatRouteProfile.resolve("gpt-5.6-sol"))
    XCTAssertEqual(
      TatwoChatCommandPlanner.runtimeAdapterForTurn(
        route: route,
        interactionMode: .standard,
        hasImageAttachments: false,
        nativeDevelopmentAccess: decision.access,
        preferNativeSubscription: true),
      .nativeAgent)
  }

  func testNaturalLanguageNumberedConstructionPromptUsesNativeAgent() throws {
    let prompt = """
      延續同一個既有 /goal 與 contract，不建立新 Goal。本輪純文字，不讀任何歷史附件。Host 已用新 candidate 的獨立 Island 視窗實機截圖驗證：上一輪仍未達標。

      目前 692×172 展開島在純白桌布上呈現：整個中央是不透明中灰板；底部沿全寬另有約 10–14pt 近白色厚帶，明確像第二底板；頂部黑 notch 有 4.5pt 模糊光暈；完全看不到桌布折射。這否定「移除兩層後已解決」的判斷，也不是只需再調 alpha。

      Host 已查本機真值：macOS 27.0、Xcode 27.0。官方 SDK 公開 NSGlassEffectView（macOS 26+，style regular/clear、tintColor、cornerRadius）以及 SwiftUI .glassEffect(_:in:) 與 GlassEffectContainer。目標是跟當前 macOS 27 Liquid Glass 一模一樣，所以 macOS 27 主路徑必須改用系統原生 Liquid Glass，而不是 NSVisualEffectView + WebGL + 黑色 depth fill 三層手工仿製。

      請直接施工：
      1. 在 TatwoIslandShell 的 macOS 27 路徑以單一原生 glassEffect/NSGlassEffectView 作為唯一底板，套 TatwoIslandShellShape；不要再同時疊 TatwoIslandNativeGlass、TatwoIslandLiquidGlassFilter 的 WebGL 與黑色 depth fill。
      2. Dashboard 真值全部保留且不可修改；它只可留作舊系統 fallback，不得參與 macOS 27 Island 主路徑。
      3. 移除底部厚白帶的來源；檢查 shader shadow、mask alpha、clip 與任何額外 stroke。macOS 27 主路徑只准一個系統玻璃表面與系統自然邊緣。
      4. TatwoIslandNotchBlackPaint 的黑 notch 必須保持，但 4.5pt blur 不得溢出成灰板/光暈；改成限制在 notch 區域內的漸淡或 mask。
      5. 移除不再需要的桌布取樣/手工 rim，順便消除本輪新增的 observer Sendable 警告；不可新增第二套仿製高光。
      6. 只修改 LiquidGlassPanelMaterial.swift、TatwoIslandShell.swift、TatwoIslandShellTests.swift；保留 dirty，禁止 reset/clean/stash；只用 TATWO 原生工具、Claude 訂閱登入、tatwo-native-agent，禁止 API/API Key、gateway-direct、Claude 內建 shell、fallback；build/test --jobs 2。

      新增測試明確證明 macOS 27 主路徑使用原生 glassEffect、沒有 WebGL/NSVisualEffectView/手工 depth/rim 重複底板，且 notch blur 不外溢。完成後回報 tool receipts、exit codes、測試數與 route/model/effort/auth/fallback；未經下一個 Computer Use candidate 截圖禁止宣稱 perfect。
      """
    let decision = TatwoChatCommandPlanner.nativeDevelopmentDecision(
      currentVisibleTurn: prompt,
      mode: .chat,
      interactionMode: .standard,
      scenarioPhase: .loops,
      contractStatus: .running)

    XCTAssertTrue(decision.requested)
    XCTAssertEqual(decision.access, .mutation)
    let route = try XCTUnwrap(TatwoChatRouteProfile.resolve("opus5"))
    XCTAssertEqual(
      TatwoChatCommandPlanner.runtimeAdapterForTurn(
        route: route,
        interactionMode: .standard,
        hasImageAttachments: false,
        nativeDevelopmentAccess: decision.access,
        preferNativeSubscription: true),
      .nativeAgent)
  }

  func testExactSolE2EInvokeChecklistAuthorizesNativeRuntime() throws {
    let prompt = """
      只延續目前既有 Goal／contract，不建立新 Goal，不開始 Opus 或 Liquid Glass。現在只做 Sol E2E 驗證。

      設定必須是：GPT-5.6 Sol、High、ChatGPT 訂閱登入、zero fallback；禁止 API／API Key。權威工作樹是 /tmp/tatwo2-fixture/repos/Tatwo Ultrawork/.worktrees/tatwo-native-runtime。

      請實際依序呼叫 TATWO 原生工具：
      1. read_file：Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/ChatPageModel.swift
      2. git_diff：Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/HostExecutor.swift
      3. run_command：{"executable":"pwd","arguments":[],"timeout_seconds":30}
      4. run_command：{"executable":"git","arguments":["status","--short"],"timeout_seconds":30}
      5. run_command：{"executable":"swift","arguments":["test","--filter","HostExecutorTests"],"timeout_seconds":900}
      6. run_command：{"executable":"swift","arguments":["test","--filter","TatwoNativeDevelopmentToolTests"],"timeout_seconds":900}

      不要修改檔案。最後逐項回報 tool receipt、exit code、實際 cwd，並回報 runtimeAdapter、實際 model、effort、subscription auth、fallbackCount。任何一項無法以原生證據確認，就明確 FAIL 並停止。
      """
    let decision = TatwoChatCommandPlanner.nativeDevelopmentDecision(
      currentVisibleTurn: prompt,
      mode: .chat,
      interactionMode: .standard,
      scenarioPhase: .loops,
      contractStatus: .running)

    XCTAssertTrue(decision.requested)
    XCTAssertEqual(decision.access, .readOnly)
    let route = try XCTUnwrap(
      TatwoChatRouteProfile.resolve("gpt-5.6-sol"))
    XCTAssertEqual(
      TatwoChatCommandPlanner.runtimeAdapterForTurn(
        route: route,
        interactionMode: .standard,
        hasImageAttachments: false,
        nativeDevelopmentAccess: decision.access,
        preferNativeSubscription: true),
      .nativeAgent)
  }

  func testNumberedToolNamesWithoutExplicitChecklistLeadRemainContextOnly() {
    let decision = TatwoChatCommandPlanner.nativeDevelopmentDecision(
      currentVisibleTurn:
        "診斷紀錄：\n1. read_file 回傳失敗。\n2. run_command 沒有執行。",
      mode: .chat,
      interactionMode: .standard,
      scenarioPhase: .loops,
      contractStatus: .running)

    XCTAssertFalse(decision.requested)
    XCTAssertEqual(decision.access, .none)
  }

  func testCurrentTurnDevelopmentAccessFailsClosedWithoutExecutableContract() {
    for status in [
      nil,
      .cancelled,
      .failed,
      .succeeded,
      .passed,
      .superseded,
      .rollbackRequired,
    ] as [GoalRunStatus?] {
      XCTAssertEqual(
        TatwoChatCommandPlanner.nativeDevelopmentAccess(
          currentVisibleTurn: "請修改程式並執行測試。",
          mode: .chat,
          interactionMode: .standard,
          scenarioPhase: .loops,
          contractStatus: status),
        .none,
        "status=\(String(describing: status))")
    }
  }

  func testStandaloneDevelopmentImperativesNeverFallBackToCompatibilityRoutes()
    throws
  {
    let cases: [(String, TatwoNativeDevelopmentAccess)] = [
      ("請執行測試", .mutation),
      ("請跑測試", .mutation),
      ("run tests", .mutation),
      ("run build", .mutation),
      ("把 app test 修好", .mutation),
      ("將 runtime 修改完成", .mutation),
      ("git status", .readOnly),
      ("git diff", .readOnly),
      ("pwd", .readOnly),
    ]
    for routeID in ["gpt-5.6-sol", "opus5"] {
      let route = try XCTUnwrap(TatwoChatRouteProfile.resolve(routeID))
      for (turn, expectedAccess) in cases {
        let active = TatwoChatCommandPlanner.nativeDevelopmentDecision(
          currentVisibleTurn: turn,
          mode: .chat,
          interactionMode: .standard,
          scenarioPhase: .loops,
          contractStatus: .running)
        XCTAssertTrue(active.requested, "\(routeID): \(turn)")
        XCTAssertEqual(active.access, expectedAccess, "\(routeID): \(turn)")
        XCTAssertEqual(
          TatwoChatCommandPlanner.runtimeAdapterForTurn(
            route: route,
            interactionMode: .standard,
            hasImageAttachments: false,
            nativeDevelopmentAccess: active.access),
          route.engine == .codex ? .codexExec : .claudeCLI,
          "\(routeID): \(turn)")

        for status in [nil, GoalRunStatus.cancelled] {
          let denied = TatwoChatCommandPlanner.nativeDevelopmentDecision(
            currentVisibleTurn: turn,
            mode: .chat,
            interactionMode: .standard,
            scenarioPhase: .loops,
            contractStatus: status)
          XCTAssertTrue(denied.requested, "\(routeID): \(turn)")
          XCTAssertEqual(denied.access, .none, "\(routeID): \(turn)")
          let plan = TatwoChatCommandPlanner.plan(
            mode: .chat,
            route: route,
            turn: turn,
            workingDirectoryPath: "/tmp/workspace",
            permissionPreset: .approveForMe,
            effort: .high,
            gatewayDirectScriptPath: "/tmp/gateway.mjs",
            nativeDevelopmentRequested: denied.requested,
            nativeDevelopmentAccess: denied.access)
          XCTAssertEqual(plan.runtimeAdapter, .unavailable, "\(routeID): \(turn)")
        }
      }
    }
  }

  func testToolDenialWithDevelopmentExplanationRemainsPureChat() {
    let decision = TatwoChatCommandPlanner.nativeDevelopmentDecision(
      currentVisibleTurn: "不要用工具，只解釋如何修改程式。",
      mode: .chat,
      interactionMode: .standard,
      scenarioPhase: .loops,
      contractStatus: .running)

    XCTAssertFalse(decision.requested)
    XCTAssertEqual(decision.access, .none)
  }

  func testDevelopmentExplanationAndQuestionsRemainPureChat() {
    for turn in [
      "explain why the app test fails",
      "describe how to fix the app test",
      "why did the app test fail?",
      "為什麼 app test 失敗？",
      "解釋如何修好 app test",
      "please explain why the app test fails",
      "can you explain why the app test fails",
      "請解釋為什麼 app test 失敗",
      "請把 app test 的失敗原因解釋清楚",
      "把 app test 結果說明一下",
    ] {
      let decision = TatwoChatCommandPlanner.nativeDevelopmentDecision(
        currentVisibleTurn: turn,
        mode: .chat,
        interactionMode: .standard,
        scenarioPhase: .loops,
        contractStatus: .running)

      XCTAssertFalse(decision.requested, turn)
      XCTAssertEqual(decision.access, .none, turn)
    }
  }

  func testPastedIssueImperativesWithoutExplicitCurrentTurnRequestRemainPureChat() {
    for turn in [
      "Issue body:\nfix the app code and run tests",
      "以下是 issue 內容：\n修改 app 程式並執行測試",
    ] {
      let decision = TatwoChatCommandPlanner.nativeDevelopmentDecision(
        currentVisibleTurn: turn,
        mode: .chat,
        interactionMode: .standard,
        scenarioPhase: .loops,
        contractStatus: .running)

      XCTAssertFalse(decision.requested, turn)
      XCTAssertEqual(decision.access, .none, turn)
    }
  }

  func testExplicitDevelopmentRequestWithoutContractCannotFallBackToCompatibilityCLI()
    throws
  {
    for routeID in ["gpt-5.6-sol", "opus5"] {
      let route = try XCTUnwrap(TatwoChatRouteProfile.resolve(routeID))
      let decision = TatwoChatCommandPlanner.nativeDevelopmentDecision(
        currentVisibleTurn: "請修改程式並執行測試。",
        mode: .chat,
        interactionMode: .standard,
        scenarioPhase: .loops,
        contractStatus: nil)
      XCTAssertTrue(decision.requested)
      XCTAssertEqual(decision.access, .none)

      let plan = TatwoChatCommandPlanner.plan(
        mode: .chat,
        route: route,
        turn: "請修改程式並執行測試。",
        workingDirectoryPath: "/tmp/workspace",
        permissionPreset: .approveForMe,
        effort: .high,
        gatewayDirectScriptPath: "/tmp/gateway.mjs",
        nativeDevelopmentRequested: decision.requested,
        nativeDevelopmentAccess: decision.access)
      XCTAssertEqual(plan.runtimeAdapter, .unavailable, routeID)
    }
  }

  func testPlanReadOnlyDiscoveryUsesNativeForSolAndOpus() throws {
    for routeID in ["gpt-5.6-sol", "opus5"] {
      let route = try XCTUnwrap(TatwoChatRouteProfile.resolve(routeID))
      let decision = TatwoChatCommandPlanner.nativeDevelopmentDecision(
        currentVisibleTurn: "請讀取 README 並搜尋 TODO。",
        mode: .chat,
        interactionMode: .plan,
        scenarioPhase: .plan,
        contractStatus: .planned)
      XCTAssertEqual(decision.access, .readOnly)
      XCTAssertEqual(
        TatwoChatCommandPlanner.runtimeAdapterForTurn(
          route: route,
          interactionMode: .plan,
          hasImageAttachments: false,
          nativeDevelopmentAccess: decision.access),
        route.engine == .codex ? .codexExec : .claudeCLI,
        routeID)
    }
  }

  func testPlanDowngradesMutationRequestToNativeReadOnlyAndQuotedHistoryNeverGrantsAuthority()
    throws
  {
    XCTAssertEqual(
      TatwoChatCommandPlanner.nativeDevelopmentAccess(
        currentVisibleTurn: "請修改程式並執行測試。",
        mode: .chat,
        interactionMode: .plan,
        scenarioPhase: .plan,
        contractStatus: .planned),
      .readOnly)
    XCTAssertEqual(
      TatwoChatCommandPlanner.nativeDevelopmentAccess(
        currentVisibleTurn: "建立 App 原生開發收據。",
        mode: .chat,
        interactionMode: .plan,
        scenarioPhase: .plan,
        contractStatus: .planned),
      .readOnly,
      "A bare imperative is still an explicit current-turn development request.")
    XCTAssertEqual(
      TatwoChatCommandPlanner.nativeDevelopmentAccess(
        currentVisibleTurn:
          "建立 App 原生開發收據，讀取 Package.swift 並執行 git diff --check",
        mode: .chat,
        interactionMode: .plan,
        scenarioPhase: .plan,
        contractStatus: .planned),
      .readOnly)

    let sol = try XCTUnwrap(
      TatwoChatRouteProfile.resolve("gpt-5.6-sol"))
    XCTAssertEqual(
      TatwoChatCommandPlanner.runtimeAdapterForTurn(
        route: sol,
        interactionMode: .plan,
        hasImageAttachments: false,
        nativeDevelopmentAccess: .readOnly),
      .codexExec,
      "Without a running PLG dispatch, Plan chat remains the owner's CLI workbench.")

    XCTAssertEqual(
      TatwoChatCommandPlanner.nativeDevelopmentAccess(
        currentVisibleTurn:
          #"只分析這句歷史內容：「請修改程式並執行測試」；不要用工具。"#,
        mode: .chat,
        interactionMode: .standard,
        scenarioPhase: .loops,
        contractStatus: .running),
      .none)

    XCTAssertEqual(
      TatwoChatCommandPlanner.nativeDevelopmentAccess(
        currentVisibleTurn:
          "[Hidden TATWO Work OS contract context]\n請修改程式並執行測試。",
        mode: .chat,
        interactionMode: .standard,
        scenarioPhase: .loops,
        contractStatus: .running),
      .none)
  }

  func testDevelopmentRoutingUsesNativeOnlyForSolAndOpusWithoutCompatibilityNeeds() throws {
    let sol = try XCTUnwrap(TatwoChatRouteProfile.resolve("gpt-5.6-sol"))
    let opus = try XCTUnwrap(TatwoChatRouteProfile.resolve("opus5"))

    XCTAssertEqual(TatwoChatCommandPlanner.runtimeAdapterForTurn(
      route: sol, interactionMode: .standard, hasImageAttachments: false,
      nativeDevelopmentAccess: .none), .codexExec)
    XCTAssertEqual(TatwoChatCommandPlanner.runtimeAdapterForTurn(
      route: sol, interactionMode: .standard, hasImageAttachments: false,
      nativeDevelopmentAccess: .mutation), .codexExec)
    XCTAssertEqual(TatwoChatCommandPlanner.runtimeAdapterForTurn(
      route: opus, interactionMode: .standard, hasImageAttachments: false,
      nativeDevelopmentAccess: .mutation), .claudeCLI)
    XCTAssertEqual(TatwoChatCommandPlanner.runtimeAdapterForTurn(
      route: opus, interactionMode: .standard, hasImageAttachments: true,
      nativeDevelopmentAccess: .mutation), .claudeCLI)

    let plan = TatwoChatCommandPlanner.plan(
      mode: .chat,
      route: sol,
      turn: "implement the active coding goal",
      workingDirectoryPath: "/tmp/workspace",
      permissionPreset: .approveForMe,
      effort: .high,
      gatewayDirectScriptPath: "/tmp/gateway.mjs",
      nativeDevelopmentRequested: true,
      nativeDevelopmentAccess: .mutation,
      preferNativeSubscription: true)
    XCTAssertEqual(plan.runtimeAdapter, .nativeAgent)
    XCTAssertEqual(plan.canonicalModelSlug, "gpt-5.6-sol")
    XCTAssertEqual(plan.executable, "/usr/bin/false")
  }

  func testWorkOSSubscriptionPreferenceKeepsTextOnlyOpusOnNativeAgent()
    throws
  {
    let opus = try XCTUnwrap(TatwoChatRouteProfile.resolve("opus5"))

    XCTAssertEqual(
      TatwoChatCommandPlanner.runtimeAdapterForTurn(
        route: opus,
        interactionMode: .standard,
        hasImageAttachments: false,
        nativeDevelopmentAccess: .none,
        preferNativeSubscription: true),
      .nativeAgent)
    XCTAssertEqual(
      TatwoChatCommandPlanner.runtimeAdapterForTurn(
        route: opus,
        interactionMode: .standard,
        hasImageAttachments: false,
        nativeDevelopmentAccess: .none,
        preferNativeSubscription: false),
      .claudeCLI)
  }

  func testOpusNativeDevelopmentKeepsAppNativeRouteForConfiguredEffort()
    throws
  {
    let opus = try XCTUnwrap(TatwoChatRouteProfile.resolve("opus5"))

    XCTAssertEqual(
      TatwoChatCommandPlanner.runtimeAdapterForTurn(
        route: opus,
        interactionMode: .standard,
        hasImageAttachments: false,
        nativeDevelopmentAccess: .mutation,
        preferNativeSubscription: true),
      .nativeAgent)

    let xhighPlan = TatwoChatCommandPlanner.plan(
      mode: .chat,
      route: opus,
      turn: "implement the active coding goal",
      workingDirectoryPath: "/tmp/workspace",
      permissionPreset: .approveForMe,
      effort: .xhigh,
      gatewayDirectScriptPath: "/tmp/gateway.mjs",
      nativeDevelopmentRequested: true,
      nativeDevelopmentAccess: .mutation,
      preferNativeSubscription: true)
    XCTAssertEqual(xhighPlan.runtimeAdapter, .nativeAgent)
  }

  func testGatewayTransportEncodesToolsCallsAndOutputsAndParsesCalls() async throws {
    let capture = NativeRequestCapture()
    let transport = TatwoNativeGatewayModelTransport(
      endpoint: URL(string: "http://127.0.0.1:4177/v1/responses")!,
      modelID: "gpt-5.6-sol",
      effort: "high",
      requestTimeout: 123,
      headerProvider: NativeTestHeaderProvider(),
      send: { request in
        await capture.record(request)
        let body = #"{"model":"gpt-5.6-sol","fallback_count":0,"model_attestation":{"requested_model":"gpt-5.6-sol","actual_canonical_model":"gpt-5.6-sol","actual_vendor_model":"gpt-5.6-sol","fallback_count":0,"outcome":"VERIFIED_EXACT","exact":true},"reasoning_control":{"normalized":"high"},"output":[{"type":"function_call","call_id":"call-2","name":"search","arguments":"{\"query\":\"TODO\"}"}]}"#
        return (Data(body.utf8), HTTPURLResponse(
          url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
      })

    let turn = try await transport.respond(to: TatwoNativeModelRequest(
      input: [
        .userText("inspect"),
        .toolCall(TatwoNativeToolCall(
          id: "call-1", name: "read_file", argumentsJSON: #"{"path":"a.swift"}"#)),
        .toolResult(TatwoNativeToolResult(callID: "call-1", output: "body")),
      ],
      tools: [TatwoNativeToolDefinition(
        name: "read_file", description: "Read", inputSchemaJSON: #"{"type":"object"}"#)],
      modelStep: 2))

    XCTAssertEqual(turn.attestation, TatwoNativeModelAttestation(
      modelID: "gpt-5.6-sol", effort: "high", fallbackCount: 0))
    XCTAssertEqual(turn.response, .toolCalls([
      TatwoNativeToolCall(
        id: "call-2", name: "search", argumentsJSON: #"{"query":"TODO"}"#),
    ]))

    let capturedRequest = await capture.request()
    let request = try XCTUnwrap(capturedRequest)
    let data = try XCTUnwrap(request.httpBody)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(object["model"] as? String, "gpt-5.6-sol")
    XCTAssertEqual(request.value(forHTTPHeaderField: "X-Tatwo-Test"), "injected")
    XCTAssertEqual(request.timeoutInterval, 123)
    XCTAssertEqual((object["reasoning"] as? [String: Any])?["effort"] as? String, "high")
    let tools = try XCTUnwrap(object["tools"] as? [[String: Any]])
    XCTAssertEqual(tools.first?["type"] as? String, "function")
    XCTAssertEqual(tools.first?["name"] as? String, "read_file")
    XCTAssertNil(tools.first?["strict"])
    let input = try XCTUnwrap(object["input"] as? [[String: Any]])
    XCTAssertEqual(input.map { $0["type"] as? String }, ["message", "function_call", "function_call_output"])
    XCTAssertEqual(input[2]["call_id"] as? String, "call-1")
  }

  func testGatewayTransportAcceptsOnlyExactOpusCanonicalAliasAttestation() async throws {
    let transport = TatwoNativeGatewayModelTransport(
      endpoint: URL(string: "http://127.0.0.1:4177/v1/responses")!,
      modelID: "opus-5",
      effort: "high",
      send: { request in
        let body = """
        {
          "model":"claude-opus-5",
          "fallback_count":0,
          "model_attestation":{
            "schema":"TatwoGatewayModelAttestationV1",
            "requested_model":"opus-5",
            "actual_canonical_model":"opus-5",
            "actual_vendor_model":"claude-opus-5",
            "fallback_count":0,
            "outcome":"VERIFIED_EXACT",
            "exact":true
          },
          "reasoning_control":{"requested":"high","normalized":"high"},
          "output":[{"type":"message","content":[{"type":"output_text","text":"ok"}]}]
        }
        """
        return (Data(body.utf8), HTTPURLResponse(
          url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
      })

    let turn = try await transport.respond(to: TatwoNativeModelRequest(
      input: [.userText("review")], tools: [], modelStep: 1))

    XCTAssertEqual(turn.attestation, TatwoNativeModelAttestation(
      modelID: "opus-5", effort: "high", fallbackCount: 0))
    XCTAssertEqual(turn.response, .assistantText("ok"))
  }

  func testGatewayTransportRejectsUnapprovedModelAliasAndDegradedCompletion() async {
    for body in [
      """
      {
        "model":"claude-sonnet-5",
        "fallback_count":0,
        "model_attestation":{
          "requested_model":"opus-5",
          "actual_canonical_model":"sonnet-5",
          "actual_vendor_model":"claude-sonnet-5",
          "fallback_count":0,
          "outcome":"VERIFIED_EXACT",
          "exact":true
        },
        "reasoning_control":{"normalized":"high"},
        "output":[{"type":"message","content":[{"type":"output_text","text":"wrong"}]}]
      }
      """,
      """
      {
        "model":"opus-5",
        "requested_model":"opus-5",
        "degraded":true,
        "error_kind":"auth",
        "retry_allowed":false,
        "output":[{"type":"message","content":[{"type":"output_text","text":"notice"}]}]
      }
      """,
    ] {
      let transport = TatwoNativeGatewayModelTransport(
        endpoint: URL(string: "http://127.0.0.1:4177/v1/responses")!,
        modelID: "opus-5",
        effort: "high",
        send: { request in
          (Data(body.utf8), HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: nil)!)
        })
      do {
        _ = try await transport.respond(to: TatwoNativeModelRequest(
          input: [.userText("review")], tools: [], modelStep: 1))
        XCTFail("expected fail-closed attestation rejection")
      } catch let error as TatwoNativeGatewayTransportError {
        XCTAssertEqual(error, .attestationMismatch)
      } catch {
        XCTFail("unexpected error: \(error)")
      }
    }
  }

  func testGatewayTransportRejectsModelEffortAndFallbackMismatch() async {
    let transport = TatwoNativeGatewayModelTransport(
      endpoint: URL(string: "http://127.0.0.1:4177/v1/responses")!,
      modelID: "opus-5",
      effort: "high",
      send: { request in
        let body = #"{"model":"fallback-model","effort":"low","fallback_count":1,"output":[{"type":"message","content":[{"type":"output_text","text":"unsafe"}]}]}"#
        return (Data(body.utf8), HTTPURLResponse(
          url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
      })

    do {
      _ = try await transport.respond(to: TatwoNativeModelRequest(
        input: [.userText("edit")], tools: [], modelStep: 1))
      XCTFail("expected attestation rejection")
    } catch let error as TatwoNativeGatewayTransportError {
      XCTAssertEqual(error, .attestationMismatch)
    } catch {
      XCTFail("unexpected error: \(error)")
    }
  }

  func testJournalRehydratesRunningAsInterrupted() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("tatwo-native-journal-\(UUID().uuidString)", isDirectory: true)
    let journal = TatwoNativeAgentRunJournal(directoryURL: root)
    let running = TatwoNativeAgentPersistedRun(
      runID: "run-1", state: .running, modelID: "gpt-5.6-sol", effort: "high")
    try journal.save(running)

    let recovered = try XCTUnwrap(journal.load(runID: "run-1"))

    XCTAssertEqual(recovered.state, .interrupted)
    XCTAssertEqual(try journal.load(runID: "run-1")?.state, .interrupted)
  }

  func testJournalRestartReconcilesEveryResidualRunningRun() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "tatwo-native-journal-restart-\(UUID().uuidString)",
        isDirectory: true)
    let journal = TatwoNativeAgentRunJournal(directoryURL: root)
    try journal.save(TatwoNativeAgentPersistedRun(
      runID: "running-a", state: .running,
      modelID: "gpt-5.6-sol", effort: "high"))
    try journal.save(TatwoNativeAgentPersistedRun(
      runID: "running-b", state: .running,
      modelID: "opus-5", effort: "high"))
    try journal.save(TatwoNativeAgentPersistedRun(
      runID: "complete", state: .completed,
      modelID: "opus-5", effort: "high"))

    XCTAssertEqual(try journal.reconcileInterruptedRuns(), 2)
    XCTAssertEqual(try journal.load(runID: "running-a")?.state, .interrupted)
    XCTAssertEqual(try journal.load(runID: "running-b")?.state, .interrupted)
    XCTAssertEqual(try journal.load(runID: "complete")?.state, .completed)
    XCTAssertEqual(try journal.reconcileInterruptedRuns(), 0)
  }

  func testNativeAdapterCodableRoundTripIsStable() throws {
    let data = try JSONEncoder().encode(TatwoChatRuntimeAdapter.nativeAgent)
    XCTAssertEqual(String(decoding: data, as: UTF8.self), #""tatwo-native-agent""#)
    XCTAssertEqual(
      try JSONDecoder().decode(TatwoChatRuntimeAdapter.self, from: data),
      .nativeAgent)
  }
}

private actor NativeRequestCapture {
  private var value: URLRequest?
  func record(_ request: URLRequest) { value = request }
  func request() -> URLRequest? { value }
}

private struct NativeTestHeaderProvider: TatwoNativeGatewayHeaderProviding {
  func headers() throws -> [String: String] {
    ["X-Tatwo-Test": "injected"]
  }
}
