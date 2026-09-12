import XCTest
@testable import TatwoUltraworkCore

final class UnifiedExternalModelRoutingTests: XCTestCase {
  private func commaSeparatedArgumentValues(
    after flag: String,
    in arguments: [String],
    file: StaticString = #filePath,
    line: UInt = #line
  ) -> Set<String> {
    guard let index = arguments.firstIndex(of: flag),
          arguments.indices.contains(index + 1)
    else {
      XCTFail("missing \(flag) argument", file: file, line: line)
      return []
    }
    return Set(arguments[index + 1].split(separator: ",").map(String.init))
  }

  func testThreadDecodingAcceptsLegacyDevModeFieldAndMissingField() throws {
    let thread = TatwoNativeChatThread(title: "compatibility")
    let encoded = try JSONEncoder().encode(thread)
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    XCTAssertNil(object["devModeEnabled"])

    let withoutLegacyField = try JSONSerialization.data(
      withJSONObject: object)
    XCTAssertEqual(
      try JSONDecoder().decode(
        TatwoNativeChatThread.self,
        from: withoutLegacyField).title,
      "compatibility")

    object["devModeEnabled"] = true
    object["futureUnknownField"] = ["value": 1]
    let legacy = try JSONSerialization.data(withJSONObject: object)
    XCTAssertEqual(
      try JSONDecoder().decode(TatwoNativeChatThread.self, from: legacy).title,
      "compatibility")
  }

  func testDefaultRoutesEverySupportedModelToItsNativeCLI() {
    let expected: [(String, TatwoChatRuntimeAdapter)] = [
      ("gpt-5.6-sol", .codexExec),
      ("fable5", .claudeCLI),
      ("opus5", .claudeCLI),
      ("sonnet5", .claudeCLI),
      ("haiku4.5", .claudeCLI),
      ("grok-build", .grokCLI),
    ]
    for (id, adapter) in expected {
      XCTAssertEqual(
        TatwoChatCommandPlanner.runtimeAdapterForTurn(
          route: TatwoChatRouteProfile.resolve(id),
          interactionMode: .standard,
          hasImageAttachments: false),
        adapter,
        id)
    }
    let minimax = TatwoChatCommandPlanner.runtimeRouteDecisionForTurn(
      route: TatwoChatRouteProfile.resolve("minimax-m3"),
      interactionMode: .standard,
      hasImageAttachments: false)
    XCTAssertEqual(minimax.adapter, .minimaxDirect)
    XCTAssertNil(minimax.fallbackReason)
  }

  func testGoalBoundOrdinaryDevelopmentTurnKeepsProviderCLIMatrix() {
    let expected: [(String, TatwoChatRuntimeAdapter)] = [
      ("gpt-5.6-sol", .codexExec),
      ("fable5", .claudeCLI),
      ("grok-build", .grokCLI),
    ]
    for (routeID, adapter) in expected {
      XCTAssertEqual(
        TatwoChatCommandPlanner.runtimeAdapterForTurn(
          route: TatwoChatRouteProfile.resolve(routeID),
          interactionMode: .standard,
          hasImageAttachments: false,
          nativeDevelopmentAccess: .mutation,
          preferNativeSubscription: nil),
        adapter,
        routeID)
    }
  }

  func testProductionChatRouteTableNeverSelectsDeprecatedGatewayDirect() {
    for route in TatwoChatRouteProfile.defaults {
      XCTAssertNotEqual(
        route.runtimeAdapter,
        .gatewayDirect,
        "\(route.id) profile still points at the deprecated 4177 transport")
      for interactionMode in [
        TatwoChatInteractionMode.standard,
        TatwoChatInteractionMode.plan,
      ] {
        let decision = TatwoChatCommandPlanner.runtimeRouteDecisionForTurn(
          route: route,
          interactionMode: interactionMode,
          hasImageAttachments: false)
        XCTAssertNotEqual(
          decision.adapter,
          .gatewayDirect,
          "\(route.id) \(interactionMode) still selects deprecated gatewayDirect")
      }
    }
  }

  func testFablePATHFallbackRequiresExplicitEnvironmentAndExecutableProbe() {
    let route = TatwoChatRouteProfile.resolve("fable5")
    let withoutProbe = TatwoChatCommandPlanner.plan(
      mode: .chat,
      route: route,
      turn: "implement the change",
      workingDirectoryPath: "/tmp/tatwo-work",
      permissionPreset: .approveForMe,
      effort: .high,
      gatewayDirectScriptPath: "/tmp/tatwo-direct-gateway-chat.mjs",
      toolHostRequirementTurn: "implement the change",
      computerHostRunID: "path-fallback-run",
      computerHostTurnID: "path-fallback-turn",
      bundleURL: URL(fileURLWithPath: "/tmp/Missing.app"),
      environment: ["PATH": "/tmp"])
    XCTAssertEqual(withoutProbe.runtimeAdapter, .unavailable)
    XCTAssertEqual(withoutProbe.executable, "/usr/bin/false")
    XCTAssertEqual(
      withoutProbe.runtimeFallbackReason,
      .claudeExecutableUnavailable)
    XCTAssertFalse(
      withoutProbe.arguments.contains(
        "/tmp/tatwo-direct-gateway-chat.mjs"))

    let nativePlan = TatwoChatCommandPlanner.plan(
      mode: .chat,
      route: route,
      turn: "implement the change",
      workingDirectoryPath: "/tmp/tatwo-work",
      permissionPreset: .approveForMe,
      effort: .high,
      gatewayDirectScriptPath: "/tmp/tatwo-direct-gateway-chat.mjs",
      environment: ["PATH": "/tmp"],
      isExecutableFile: { $0 == "/tmp/claude" })
    XCTAssertEqual(nativePlan.runtimeAdapter, .claudeCLI)
    XCTAssertEqual(nativePlan.executable, "/tmp/claude")
    XCTAssertTrue(nativePlan.arguments.contains("claude-fable-5"))
    XCTAssertFalse(nativePlan.arguments.contains("fable-5"))

  }

  func testPlannerDefaultsAreFilesystemPureAndUseBundledHelpersWhenInjected() {
    let missingPlan = TatwoChatCommandPlanner.plan(
      mode: .chat,
      route: TatwoChatRouteProfile.resolve("gpt-5.5"),
      turn: "reply",
      workingDirectoryPath: "/tmp/tatwo-work",
      permissionPreset: .approveForMe,
      effort: .high,
      gatewayDirectScriptPath: "/tmp/tatwo-direct-gateway-chat.mjs",
      toolHostRequirementTurn: "reply",
      computerHostRunID: "pure-default-run",
      computerHostTurnID: "pure-default-turn",
      bundleURL: URL(fileURLWithPath: "/tmp/Missing.app"))
    XCTAssertEqual(missingPlan.runtimeAdapter, .unavailable)
    XCTAssertEqual(missingPlan.executable, "/usr/bin/false")
    XCTAssertEqual(
      missingPlan.runtimeFallbackReason,
      .codexExecutableUnavailable)

    let bundle = URL(fileURLWithPath: "/tmp/Tatwo Ultrawork.app")
    let fixtures: [(routeID: String, helperName: String, adapter: TatwoChatRuntimeAdapter)] = [
      ("gpt-5.5", "TatwoSubscriptionRuntime", .codexExec),
      ("sonnet5", "TatwoClaudeSubscriptionRuntime", .claudeCLI),
    ]
    for fixture in fixtures {
      let helper = bundle.appendingPathComponent(
        "Contents/Helpers/\(fixture.helperName)").path
      let plan = TatwoChatCommandPlanner.plan(
        mode: .chat,
        route: TatwoChatRouteProfile.resolve(fixture.routeID),
        turn: "reply",
        workingDirectoryPath: "/tmp/tatwo-work",
        permissionPreset: .approveForMe,
        effort: .high,
        gatewayDirectScriptPath: "/tmp/tatwo-direct-gateway-chat.mjs",
        bundleURL: bundle,
        isExecutableFile: { $0 == helper })

      XCTAssertEqual(plan.runtimeAdapter, fixture.adapter, fixture.routeID)
      XCTAssertEqual(plan.executable, helper, fixture.routeID)
    }
  }

  func testGrokDefaultPlanUsesBundledRuntimeArgvPermissionsAndIsolation() {
    let bundle = URL(fileURLWithPath: "/tmp/Tatwo Ultrawork.app")
    let helper = bundle.appendingPathComponent(
      "Contents/Helpers/TatwoGrokVendorRuntime").path
    let plan = TatwoChatCommandPlanner.plan(
      mode: .chat,
      route: TatwoChatRouteProfile.resolve("grok-build"),
      turn: "edit and test",
      workingDirectoryPath: "/tmp/tatwo-work",
      permissionPreset: .approveForMe,
      effort: .high,
      gatewayDirectScriptPath: "/tmp/tatwo-direct-gateway-chat.mjs",
      bundleURL: bundle,
      environment: [
        "PATH": "/usr/bin:/bin",
        "TATWO_NATIVE_GROK_SUBSCRIPTION_HOME": "/tmp/tatwo-grok-home",
      ],
      isExecutableFile: { $0 == helper })

    XCTAssertEqual(plan.runtimeAdapter, .grokCLI)
    XCTAssertEqual(plan.executable, helper)
    XCTAssertEqual(plan.arguments, [
      "--cwd", "/tmp/tatwo-work",
      "--always-approve",
      "--output-format", "streaming-json",
      "--no-memory",
      "--no-subagents",
      // PLGFIX3C 重排：--no-plan 移到 --max-turns 之後（語義等價）。
      "--max-turns", "32",
      "--no-plan",
      "--rules",
      "For actionable requests, complete the requested work and verification in this turn. Do not stop after announcing a plan.",
      "-p", "edit and test",
    ])
    XCTAssertFalse(plan.arguments.contains("acceptEdits"))
    XCTAssertTrue(plan.capturesSessionID)
    XCTAssertEqual(plan.environmentOverrides["HOME"], "/tmp/tatwo-grok-home")
    XCTAssertEqual(
      plan.environmentOverrides["GROK_HOME"],
      "/tmp/tatwo-grok-home/.grok")
    XCTAssertEqual(
      plan.environmentOverrides["XDG_CONFIG_HOME"],
      "/tmp/tatwo-grok-home/.config")
    XCTAssertEqual(
      plan.environmentOverrides["XDG_CACHE_HOME"],
      "/tmp/tatwo-grok-home/.cache")
    XCTAssertNil(plan.runtimeFallbackReason)
  }

  func testGrokPlanInteractionUsesOnlyReadOnlyProjectTools() throws {
    let bundle = URL(fileURLWithPath: "/tmp/Tatwo Ultrawork.app")
    let helper = bundle.appendingPathComponent(
      "Contents/Helpers/TatwoGrokVendorRuntime").path
    let plan = TatwoChatCommandPlanner.plan(
      mode: .chat,
      route: TatwoChatRouteProfile.resolve("grok-build"),
      turn: "先查證專案再規劃",
      workingDirectoryPath: "/tmp/tatwo-work",
      permissionPreset: .fullAccess,
      interactionMode: .plan,
      effort: .high,
      gatewayDirectScriptPath: "/tmp/tatwo-direct-gateway-chat.mjs",
      bundleURL: bundle,
      environment: [
        "TATWO_NATIVE_GROK_SUBSCRIPTION_HOME": "/tmp/tatwo-grok-home",
      ],
      isExecutableFile: { $0 == helper })

    XCTAssertEqual(plan.runtimeAdapter, .grokCLI)
    XCTAssertEqual(plan.executable, helper)
    let permissionIndex = try XCTUnwrap(
      plan.arguments.firstIndex(of: "--permission-mode"))
    XCTAssertEqual(plan.arguments[permissionIndex + 1], "plan")
    let toolsIndex = try XCTUnwrap(plan.arguments.firstIndex(of: "--tools"))
    XCTAssertEqual(plan.arguments[toolsIndex + 1], "Read,Grep,Glob")
    let tools = Set(plan.arguments[toolsIndex + 1].split(separator: ",").map(String.init))
    XCTAssertTrue(tools.isDisjoint(with: ["Bash", "Write", "Edit", "NotebookEdit"]))
    XCTAssertTrue(plan.arguments.contains(TatwoChatInteractionMode.claudePlanSystemPrompt))
    XCTAssertFalse(plan.arguments.contains("--always-approve"))
    XCTAssertFalse(plan.arguments.contains("--no-plan"))
    XCTAssertFalse(plan.arguments.contains("bypassPermissions"))
  }

  func testGrokSecondTurnInSameThreadResumesExactSessionFromFirstTurn() throws {
    let bundle = URL(fileURLWithPath: "/tmp/Tatwo Ultrawork.app")
    let helper = bundle.appendingPathComponent(
      "Contents/Helpers/TatwoGrokVendorRuntime").path
    let sessionID = "01a01be6-f30d-7c40-970d-d06d8297a552"
    let sameThreadHandles = TatwoNativeSessionTree.upserting(
      TatwoNativeAdapterSessionHandle(
        adapterID: TatwoChatRuntimeAdapter.grokCLI.rawValue,
        modelID: "grok-build",
        providerSessionID: sessionID),
      into: [])
    let resumedSessionID = TatwoNativeSessionTree.providerSessionID(
      adapterID: TatwoChatRuntimeAdapter.grokCLI.rawValue,
      modelID: "grok-build",
      handles: sameThreadHandles)
    let first = TatwoChatCommandPlanner.plan(
      mode: .chat,
      route: TatwoChatRouteProfile.resolve("grok-build"),
      turn: "inspect",
      workingDirectoryPath: "/tmp/tatwo-work",
      permissionPreset: .approveForMe,
      effort: .high,
      gatewayDirectScriptPath: "/tmp/tatwo-direct-gateway-chat.mjs",
      bundleURL: bundle,
      environment: [
        "TATWO_NATIVE_GROK_SUBSCRIPTION_HOME":
          "/tmp/tatwo-grok-home",
      ],
      isExecutableFile: { $0 == helper })
    let second = TatwoChatCommandPlanner.plan(
      mode: .chat,
      route: TatwoChatRouteProfile.resolve("grok-build"),
      turn: "continue",
      workingDirectoryPath: "/tmp/tatwo-work",
      permissionPreset: .approveForMe,
      effort: .high,
      grokSessionID: resumedSessionID,
      gatewayDirectScriptPath: "/tmp/tatwo-direct-gateway-chat.mjs",
      bundleURL: bundle,
      environment: [
        "TATWO_NATIVE_GROK_SUBSCRIPTION_HOME":
          "/tmp/tatwo-grok-home",
      ],
      isExecutableFile: { $0 == helper })

    XCTAssertFalse(first.arguments.contains("-r"))
    let resumeIndex = try XCTUnwrap(second.arguments.firstIndex(of: "-r"))
    XCTAssertLessThan(resumeIndex + 1, second.arguments.count)
    XCTAssertEqual(second.arguments[resumeIndex + 1], sessionID)
    XCTAssertEqual(first.environmentOverrides, second.environmentOverrides)
  }

  func testGrokPermissionMappingsMatchDevelopmentContract() {
    XCTAssertEqual(
      TatwoPermissionPreset.askFirst.grokArguments,
      ["--permission-mode", "default"])
    XCTAssertEqual(
      TatwoPermissionPreset.approveForMe.grokArguments,
      ["--always-approve"])
    XCTAssertEqual(
      TatwoPermissionPreset.fullAccess.grokArguments,
      ["--always-approve"])
    for preset in TatwoPermissionPreset.allCases {
      XCTAssertFalse(preset.grokArguments.contains("acceptEdits"))
    }
  }

  func testUnavailableDevelopmentRuntimeFailsClosedWithReason() {
    let plan = TatwoChatCommandPlanner.plan(
      mode: .chat,
      route: TatwoChatRouteProfile.resolve("grok-build"),
      turn: "keep the turn alive",
      workingDirectoryPath: "/tmp/tatwo-work",
      permissionPreset: .askFirst,
      effort: .high,
      gatewayDirectScriptPath: "/tmp/tatwo-direct-gateway-chat.mjs",
      toolHostRequirementTurn: "keep the turn alive",
      computerHostRunID: "grok-fallback-run",
      computerHostTurnID: "grok-fallback-turn",
      bundleURL: URL(fileURLWithPath: "/tmp/Missing.app"),
      environment: ["PATH": "/missing"],
      isExecutableFile: { _ in false })

    XCTAssertEqual(plan.runtimeAdapter, .unavailable)
    XCTAssertEqual(plan.executable, "/usr/bin/false")
    XCTAssertEqual(
      plan.runtimeFallbackReason,
      .grokExecutableUnavailable)
    XCTAssertFalse(plan.arguments.contains("grok-build"))
    XCTAssertFalse(
      plan.arguments.contains(
        "/tmp/tatwo-direct-gateway-chat.mjs"))
  }

  func testClaudeFamilyChatRoutesUseClaudeCLIByDefault() throws {
    let expectedRoutes: [(id: String, slug: String, imageRescue: Bool)] = [
      ("haiku4.5", "haiku-4-5", true),
      ("sonnet5", "sonnet-5", true),
      ("opus5", "opus-5", true),
    ]

    for expected in expectedRoutes {
      let route = TatwoChatRouteProfile.resolve(expected.id)
      XCTAssertEqual(route.runtimeAdapter, .claudeCLI, expected.id)
      XCTAssertEqual(route.canonicalModelSlug, expected.slug, expected.id)

      let plan = TatwoChatCommandPlanner.plan(
        mode: .chat,
        route: route,
        turn: "route continuity smoke",
        workingDirectoryPath: "/tmp/tatwo-chat",
        permissionPreset: .approveForMe,
        effort: .high,
        gatewayDirectScriptPath: "/tmp/scripts/tatwo-direct-gateway-chat.mjs",
        toolHostRequirementTurn: "route continuity smoke",
        computerHostRunID: "route-continuity-\(expected.id)",
        computerHostTurnID: "route-continuity-turn",
        environment: ["PATH": "/tmp"],
        isExecutableFile: { $0 == "/tmp/claude" })

      XCTAssertEqual(plan.engine, route.engine, expected.id)
      XCTAssertEqual(plan.runtimeAdapter, .claudeCLI, expected.id)
      XCTAssertEqual(plan.executable, "/tmp/claude", expected.id)
      XCTAssertTrue(plan.arguments.contains("--permission-mode"), expected.id)
      XCTAssertTrue(plan.arguments.contains("acceptEdits"), expected.id)
      let tools = commaSeparatedArgumentValues(
        after: "--tools",
        in: plan.arguments)
      XCTAssertTrue(tools.isSuperset(of: ["Bash", "Read"]), expected.id)
      XCTAssertEqual(route.supportsImageInput, expected.imageRescue, expected.id)
    }
  }

  func testClaudeFamilyImageTurnsUseNativeClaudeRescueWithoutCodex() throws {
    let imagePath = "/tmp/tatwo-image.png"
    let bundle = URL(fileURLWithPath: "/tmp/Tatwo Ultrawork.app")
    let helper = bundle.appendingPathComponent(
      "Contents/Helpers/TatwoClaudeSubscriptionRuntime").path
    for expected in [
      (id: "haiku4.5", nativeModel: "haiku"),
      (id: "sonnet5", nativeModel: "sonnet"),
      (id: "opus5", nativeModel: "claude-opus-5"),
    ] {
      let plan = TatwoChatCommandPlanner.plan(
        mode: .chat,
        route: TatwoChatRouteProfile.resolve(expected.id),
        turn: "read the image",
        workingDirectoryPath: "/tmp/tatwo-chat",
        permissionPreset: .approveForMe,
        effort: .low,
        claudeSessionID: "claude-image-session",
        droppedPaths: [imagePath],
        gatewayDirectScriptPath: "/tmp/scripts/tatwo-direct-gateway-chat.mjs",
        bundleURL: bundle,
        isExecutableFile: { $0 == helper })

      XCTAssertEqual(plan.engine, .claude, expected.id)
      XCTAssertEqual(plan.runtimeAdapter, .claudeCLI, expected.id)
      XCTAssertEqual(plan.executable, helper, expected.id)
      XCTAssertTrue(plan.arguments.contains("--allowedTools"), expected.id)
      XCTAssertTrue(
        commaSeparatedArgumentValues(
          after: "--allowedTools",
          in: plan.arguments).contains("Read"),
        expected.id)
      XCTAssertTrue(plan.arguments.contains("--add-dir"), expected.id)
      XCTAssertTrue(plan.arguments.contains("/tmp"), expected.id)
      XCTAssertTrue(plan.arguments.contains("--resume"), expected.id)
      XCTAssertTrue(plan.arguments.contains("claude-image-session"), expected.id)
      XCTAssertTrue(plan.arguments.contains("--model"), expected.id)
      XCTAssertTrue(plan.arguments.contains(expected.nativeModel), expected.id)
      XCTAssertFalse(plan.arguments.contains(TatwoChatRouteProfile.resolve(expected.id).canonicalModelSlug), expected.id)
      XCTAssertTrue(plan.arguments.last?.contains(imagePath) == true, expected.id)
      XCTAssertFalse(plan.arguments.contains("/tmp/scripts/tatwo-direct-gateway-chat.mjs"), expected.id)
    }
  }

  func testFirstClaudeImageTurnStartsNativeSessionWithoutResume() throws {
    let bundle = URL(fileURLWithPath: "/tmp/Tatwo Ultrawork.app")
    let helper = bundle.appendingPathComponent(
      "Contents/Helpers/TatwoClaudeSubscriptionRuntime").path
    let plan = TatwoChatCommandPlanner.plan(
      mode: .chat,
      route: TatwoChatRouteProfile.resolve("haiku4.5"),
      turn: "read the first image",
      workingDirectoryPath: "/tmp/tatwo-chat",
      permissionPreset: .approveForMe,
      effort: .low,
      claudeSessionID: nil,
      droppedPaths: ["/tmp/tatwo-first-image.png"],
      gatewayDirectScriptPath: "/tmp/scripts/tatwo-direct-gateway-chat.mjs",
      bundleURL: bundle,
      isExecutableFile: { $0 == helper })

    XCTAssertEqual(plan.runtimeAdapter, .claudeCLI)
    XCTAssertTrue(plan.capturesSessionID)
    XCTAssertFalse(plan.arguments.contains("--resume"))
  }

  func testFable5UsesExactBundledClaudeRouteAndNativeImageTransport() throws {
    let route = TatwoChatRouteProfile.resolve("fable5")
    let bundle = URL(fileURLWithPath: "/tmp/Tatwo Ultrawork.app")
    let helper = bundle.appendingPathComponent(
      "Contents/Helpers/TatwoClaudeSubscriptionRuntime").path
    let plan = TatwoChatCommandPlanner.plan(
      mode: .chat,
      route: route,
      turn: "inspect the attachment",
      workingDirectoryPath: "/tmp/tatwo-chat",
      permissionPreset: .approveForMe,
      effort: .high,
      codexSessionID: "thread-fable",
      droppedPaths: ["/tmp/reference.png"],
      gatewayDirectScriptPath: "/tmp/scripts/tatwo-direct-gateway-chat.mjs",
      toolHostRequirementTurn: "inspect the attachment",
      computerHostRunID: "fable-attachment-route",
      computerHostTurnID: "fable-attachment-turn",
      bundleURL: bundle,
      isExecutableFile: { $0 == helper })

    XCTAssertEqual(route.engine, .claude)
    XCTAssertEqual(route.runtimeAdapter, .claudeCLI)
    XCTAssertTrue(route.supportsImageInput)
    XCTAssertTrue(route.acceptsAttachmentPath("/tmp/reference.png"))
    XCTAssertEqual(plan.engine, .claude)
    XCTAssertEqual(plan.runtimeAdapter, .claudeCLI)
    XCTAssertEqual(plan.executable, helper)
    XCTAssertTrue(plan.capturesSessionID)
    XCTAssertTrue(plan.arguments.contains("--model"))
    XCTAssertTrue(plan.arguments.contains("claude-fable-5"))
    XCTAssertFalse(plan.arguments.contains("fable-5"))
    XCTAssertTrue(
      plan.arguments.last?.contains("/tmp/reference.png") == true)
    XCTAssertFalse(plan.arguments.contains("thread-fable"))
    XCTAssertFalse(plan.arguments.contains("/tmp/scripts/tatwo-direct-gateway-chat.mjs"))
  }

  func testGPTChatRoutesStayOnCodexExecForActiveSessionAuthorization() throws {
    for id in [
      "gpt-5.6-sol",
      "gpt-5.6-terra",
      "gpt-5.6-luna",
      "gpt-5.5",
      "gpt-5.4",
      "codex-auto-review",
    ] {
      let route = TatwoChatRouteProfile.resolve(id)
      XCTAssertEqual(route.runtimeAdapter, .codexExec, id)
    }
  }

  func testPLGPlanningPrefersBundledSubscriptionWithoutDevelopmentTools() {
    for id in ["gpt-5.6-sol", "opus5"] {
      let route = TatwoChatRouteProfile.resolve(id)
      let adapter = TatwoChatCommandPlanner.runtimeAdapterForTurn(
        route: route,
        interactionMode: .plan,
        hasImageAttachments: false,
        nativeDevelopmentAccess: .none,
        preferNativeSubscription: true)

      XCTAssertEqual(
        adapter,
        .nativeAgent,
        "\(id) PLG planning must use the bundled subscription runtime even when host development tools are not authorized")
    }
  }

  private func argumentValue(after flag: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: flag),
          arguments.indices.contains(index + 1)
    else { return nil }
    return arguments[index + 1]
  }
}
