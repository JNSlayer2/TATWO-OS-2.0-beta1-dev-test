import XCTest
@testable import TatwoUltraworkCore

final class ComputerHostTests: XCTestCase {
  func testComputerHostTurnRoutingSelectsExactlyOneBackend() {
    let sonnet = TatwoChatRouteProfile.resolve("sonnet5")
    let fable = TatwoChatRouteProfile.resolve("fable5")
    let codex = TatwoChatRouteProfile.resolve("gpt-5.5")

    XCTAssertEqual(
      TatwoComputerHostTurnRoutingPolicy.select(
        userRequestedComputerUse: true,
        isChatMode: true,
        isPlanMode: false,
        route: sonnet),
      .mcp)
    XCTAssertEqual(
      TatwoComputerHostTurnRoutingPolicy.select(
        userRequestedComputerUse: true,
        isChatMode: true,
        isPlanMode: false,
        route: fable),
      .embeddedIntent)
    XCTAssertEqual(
      TatwoComputerHostTurnRoutingPolicy.select(
        userRequestedComputerUse: true,
        isChatMode: true,
        isPlanMode: false,
        route: codex),
      .embeddedIntent)
  }

  func testComputerHostTurnRoutingDisablesNonExecutionSurfaces() {
    let sonnet = TatwoChatRouteProfile.resolve("sonnet5")

    XCTAssertEqual(
      TatwoComputerHostTurnRoutingPolicy.select(
        userRequestedComputerUse: false,
        isChatMode: true,
        isPlanMode: false,
        route: sonnet),
      .none)
    XCTAssertEqual(
      TatwoComputerHostTurnRoutingPolicy.select(
        userRequestedComputerUse: true,
        isChatMode: false,
        isPlanMode: false,
        route: sonnet),
      .none)
    XCTAssertEqual(
      TatwoComputerHostTurnRoutingPolicy.select(
        userRequestedComputerUse: true,
        isChatMode: true,
        isPlanMode: true,
        route: sonnet),
      .none)
  }

  func testComputerApprovalPolicyUsesSelectedVisibleIntentSinglePathContract() {
    XCTAssertEqual(
      TatwoComputerApprovalPolicy.policyID,
      "macos_permission_internal_lease_visible_intent_single_path")
  }

  func testComputerApprovalPolicyDeniesWhenUserDidNotRequestComputerUse() {
    XCTAssertEqual(
      TatwoComputerApprovalPolicy.evaluate(
        userRequestedComputerUse: false,
        hasValidContract: true,
        requiredSystemPermissionGranted: true),
      .denied(.userRequestMissing))
  }

  func testComputerApprovalPolicyDeniesWithoutValidContract() {
    XCTAssertEqual(
      TatwoComputerApprovalPolicy.evaluate(
        userRequestedComputerUse: true,
        hasValidContract: false,
        requiredSystemPermissionGranted: true),
      .denied(.contractMissing))
  }

  func testComputerApprovalPolicyDeniesUntilRequiredMacOSPermissionIsGranted() {
    XCTAssertEqual(
      TatwoComputerApprovalPolicy.evaluate(
        userRequestedComputerUse: true,
        hasValidContract: true,
        requiredSystemPermissionGranted: false),
      .denied(.systemPermissionMissing))
  }

  func testComputerApprovalPolicyAllowsWithoutPerActionHumanDialog() {
    XCTAssertEqual(
      TatwoComputerApprovalPolicy.evaluate(
        userRequestedComputerUse: true,
        hasValidContract: true,
        requiredSystemPermissionGranted: true),
      .allowedOnce)
  }

  func testComputerHostPermissionPreflightMatchesEachAction() {
    let noneGranted = TatwoComputerHostStatusV1(
      backend: "test",
      accessibilityGranted: false,
      screenRecordingGranted: false)
    let allGranted = TatwoComputerHostStatusV1(
      backend: "test",
      accessibilityGranted: true,
      screenRecordingGranted: true)

    XCTAssertNil(TatwoComputerHost.missingPermission(for: .openApp, status: noneGranted))
    XCTAssertEqual(
      TatwoComputerHost.missingPermission(for: .activateApp, status: noneGranted),
      .accessibility)
    XCTAssertEqual(
      TatwoComputerHost.missingPermission(for: .typeText, status: noneGranted),
      .accessibility)
    XCTAssertEqual(
      TatwoComputerHost.missingPermission(for: .pressKey, status: noneGranted),
      .accessibility)
    XCTAssertEqual(
      TatwoComputerHost.missingPermission(for: .mouseMove, status: noneGranted),
      .accessibility)
    XCTAssertEqual(
      TatwoComputerHost.missingPermission(for: .mouseClick, status: noneGranted),
      .accessibility)
    XCTAssertEqual(
      TatwoComputerHost.missingPermission(for: .mouseDoubleClick, status: noneGranted),
      .accessibility)
    XCTAssertEqual(
      TatwoComputerHost.missingPermission(for: .scroll, status: noneGranted),
      .accessibility)
    XCTAssertNil(TatwoComputerHost.missingPermission(for: .mouseClick, status: allGranted))
    XCTAssertEqual(
      TatwoComputerHost.missingPermission(for: .screenshot, status: noneGranted),
      .screenRecording)
    XCTAssertNil(TatwoComputerHost.missingPermission(for: .screenshot, status: allGranted))
    XCTAssertEqual(
      TatwoComputerHostPermission.accessibility.systemSettingsURL?.absoluteString,
      "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    XCTAssertEqual(
      TatwoComputerHostPermission.screenRecording.systemSettingsURL?.absoluteString,
      "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
  }

  func testComputerHostUsesNativeMacOSInputInsteadOfAppleScriptAutomation() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let sourceURL = packageRoot
      .appendingPathComponent("Sources/TatwoUltraworkCore/ComputerHost.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)

    XCTAssertFalse(source.contains("/usr/bin/osascript"))
    XCTAssertFalse(source.contains("System Events"))
    XCTAssertTrue(source.contains("CGEvent("))
    XCTAssertTrue(source.contains("mouseEventSource:"))
    XCTAssertTrue(source.contains("backingScaleFactor"))
    XCTAssertTrue(source.contains(".cghidEventTap"))
    XCTAssertTrue(source.contains("macos_permission_internal_lease_visible_intent_single_path"))
    XCTAssertFalse(source.contains("humanApprovalMissing"))
    XCTAssertFalse(source.contains("appleScriptString"))
  }

  func testToolIntentParserExtractsOneActionAndRemovesMachineBlock() throws {
    let text = """
    我會先打開 App。
    <TATWO_COMPUTER_ACTION>{"schema":"TatwoComputerActionV1","action":"open_app","value":"Tatwo Ultrawork"}</TATWO_COMPUTER_ACTION>
    """
    let action = try XCTUnwrap(TatwoComputerToolIntentParser.parse(text))
    XCTAssertEqual(action.action, .openApp)
    XCTAssertEqual(action.value, "Tatwo Ultrawork")
    XCTAssertEqual(
      TatwoComputerToolIntentParser.removingIntent(from: text),
      "我會先打開 App。")
  }

  func testMalformedToolIntentDoesNotExecuteShape() {
    XCTAssertNil(TatwoComputerToolIntentParser.parse(
      #"<TATWO_COMPUTER_ACTION>{"action":"shell","value":"rm -rf /"}</TATWO_COMPUTER_ACTION>"#))
    XCTAssertNil(TatwoComputerToolIntentParser.parse(
      #"<TATWO_COMPUTER_ACTION>{"schema":"wrong","action":"open_app","value":"Tatwo"}</TATWO_COMPUTER_ACTION>"#))
    XCTAssertNil(TatwoComputerToolIntentParser.parse(
      #"<TATWO_COMPUTER_ACTION>{"schema":"TatwoComputerActionV1","action":"open_app","value":"Tatwo"}</TATWO_COMPUTER_ACTION><TATWO_COMPUTER_ACTION>{"schema":"TatwoComputerActionV1","action":"press_key","value":"return"}</TATWO_COMPUTER_ACTION>"#))
  }

  func testMouseValueParsingAcceptsStrictPointsAndScrollDeltas() throws {
    XCTAssertEqual(
      try TatwoComputerPointerCodec.parsePoint("100,200"),
      TatwoComputerPointerValue(x: 100, y: 200, deltaX: 0, deltaY: 0))
    XCTAssertEqual(
      try TatwoComputerPointerCodec.parsePoint(" 10 , 20 "),
      TatwoComputerPointerValue(x: 10, y: 20, deltaX: 0, deltaY: 0))
    XCTAssertEqual(
      try TatwoComputerPointerCodec.parseScroll("100,200,-12,8"),
      TatwoComputerPointerValue(x: 100, y: 200, deltaX: -12, deltaY: 8))
  }

  func testMouseValueParsingRejectsInvalidShapes() {
    for value in ["", "100", "100,200,1", "10.5,20", "a,b", "100,", ",200", "1 00,200"] {
      XCTAssertThrowsError(try TatwoComputerPointerCodec.parsePoint(value), value) { error in
        XCTAssertEqual(
          error as? TatwoComputerPointerParseError, .invalidValue, value)
      }
    }
    for value in ["100,200,1", "100,200", "100,200,1.5,2", "100,200,,2"] {
      XCTAssertThrowsError(try TatwoComputerPointerCodec.parseScroll(value), value) { error in
        XCTAssertEqual(
          error as? TatwoComputerPointerParseError, .invalidValue, value)
      }
    }
  }

  func testScreenshotPixelCoordinatesConvertByBackingScaleFactor() throws {
    let main = TatwoComputerDisplayMetrics(
      isMain: true,
      pixelWidth: 3456,
      pixelHeight: 2234,
      backingScaleFactor: 2,
      quartzX: 0,
      quartzY: 0,
      quartzWidth: 1728,
      quartzHeight: 1117)
    XCTAssertEqual(
      try TatwoComputerPointerCodec.quartzPoint(pixelX: 200, pixelY: 100, displays: [main]),
      TatwoComputerQuartzPoint(x: 100, y: 50))
    XCTAssertEqual(
      try TatwoComputerPointerCodec.quartzPoint(pixelX: 0, pixelY: 0, displays: [main]),
      TatwoComputerQuartzPoint(x: 0, y: 0))
    XCTAssertThrowsError(
      try TatwoComputerPointerCodec.quartzPoint(pixelX: 3456, pixelY: 0, displays: [main])
    ) { error in
      XCTAssertEqual(error as? TatwoComputerPointerParseError, .outOfBounds)
    }
    XCTAssertThrowsError(
      try TatwoComputerPointerCodec.quartzPoint(pixelX: 0, pixelY: 2234, displays: [main])
    ) { error in
      XCTAssertEqual(error as? TatwoComputerPointerParseError, .outOfBounds)
    }
  }

  func testNonMainDisplayCoordinatesAreRejectedWithExplicitError() {
    let main = TatwoComputerDisplayMetrics(
      isMain: true,
      pixelWidth: 1440,
      pixelHeight: 900,
      backingScaleFactor: 1,
      quartzX: 0,
      quartzY: 0,
      quartzWidth: 1440,
      quartzHeight: 900)
    let other = TatwoComputerDisplayMetrics(
      isMain: false,
      pixelWidth: 1920,
      pixelHeight: 1080,
      backingScaleFactor: 1,
      quartzX: 1440,
      quartzY: 0,
      quartzWidth: 1920,
      quartzHeight: 1080)
    XCTAssertThrowsError(
      try TatwoComputerPointerCodec.quartzPoint(
        pixelX: 1500, pixelY: 10, displays: [main, other])
    ) { error in
      XCTAssertEqual(error as? TatwoComputerPointerParseError, .nonMainDisplay)
    }
  }

  func testKeyCodecParsesLettersDigitsAndModifierChords() throws {
    let letter = try XCTUnwrap(TatwoComputerKeyCodec.parse("c"))
    XCTAssertEqual(letter.virtualKeyCode, 8)
    XCTAssertFalse(letter.command)
    let chord = try XCTUnwrap(TatwoComputerKeyCodec.parse("cmd+c"))
    XCTAssertEqual(chord.virtualKeyCode, 8)
    XCTAssertTrue(chord.command)
    XCTAssertFalse(chord.shift)
    let tab = try XCTUnwrap(TatwoComputerKeyCodec.parse("cmd+tab"))
    XCTAssertEqual(tab.virtualKeyCode, 48)
    XCTAssertTrue(tab.command)
    let shiftT = try XCTUnwrap(TatwoComputerKeyCodec.parse("cmd+shift+t"))
    XCTAssertEqual(shiftT.virtualKeyCode, 17)
    XCTAssertTrue(shiftT.command)
    XCTAssertTrue(shiftT.shift)
    XCTAssertNotNil(TatwoComputerKeyCodec.parse("0"))
    XCTAssertNotNil(TatwoComputerKeyCodec.parse("space"))
    XCTAssertNotNil(TatwoComputerKeyCodec.parse("delete"))
    XCTAssertNotNil(TatwoComputerKeyCodec.parse("cmd+q"))
    XCTAssertNil(TatwoComputerKeyCodec.parse("cmd+"))
    XCTAssertNil(TatwoComputerKeyCodec.parse("cmd++c"))
    XCTAssertNil(TatwoComputerKeyCodec.parse("super+c"))
    XCTAssertNil(TatwoComputerKeyCodec.parse(""))
  }

  #if os(macOS)
  func testComputerActionRequiresContractBoundLease() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("tatwo-computer-host-\(UUID().uuidString)", isDirectory: true)
    let workspace = root.appendingPathComponent("workspace", isDirectory: true)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    let store = TatwoGoalRunStore(directoryURL: root.appendingPathComponent("goals"))
    let contract = try WorkOSFactory.issueDetachedFixtureForTesting(
      mode: .m, scenarioProfileID: "debug", objective: "computer host test", store: store)
    let approvals = TatwoHostApprovalStore(
      directoryURL: root.appendingPathComponent("approvals"), goalRunStore: store)
    let host = TatwoComputerHost(approvalStore: approvals)

    XCTAssertThrowsError(try host.execute(
      contractID: contract.contractID,
      leaseID: "missing",
      workspaceRoot: workspace.path,
      action: .openApp,
      value: "Tatwo Ultrawork"))
  }

  func testScreenshotPathEscapeFailsBeforePermissionPrompt() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("tatwo-computer-host-\(UUID().uuidString)", isDirectory: true)
    let workspace = root.appendingPathComponent("workspace", isDirectory: true)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    let store = TatwoGoalRunStore(directoryURL: root.appendingPathComponent("goals"))
    let contract = try WorkOSFactory.issueDetachedFixtureForTesting(
      mode: .m, scenarioProfileID: "debug", objective: "computer path test", store: store)
    let approvals = TatwoHostApprovalStore(
      directoryURL: root.appendingPathComponent("approvals"), goalRunStore: store)
    let lease = try approvals.issue(
      contractID: contract.contractID,
      workspaceRoot: workspace.path,
      allowedActions: [.computerUse])
    let host = TatwoComputerHost(approvalStore: approvals)

    XCTAssertThrowsError(try host.execute(
      contractID: contract.contractID,
      leaseID: lease.id,
      workspaceRoot: workspace.path,
      action: .screenshot,
      value: "../escape.png")) { error in
        XCTAssertEqual(error as? TatwoHostExecutorError, .invalidRelativePath)
      }
    XCTAssertThrowsError(try approvals.require(
      id: lease.id,
      contractID: contract.contractID,
      workspaceRoot: workspace.path,
      action: .computerUse)) { error in
        XCTAssertEqual(error as? TatwoHostExecutorError, .approvalRequired)
      }
  }

  func testScreenshotRefusesToOverwriteExistingArtifactBeforePermissionPrompt() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("tatwo-computer-host-\(UUID().uuidString)", isDirectory: true)
    let workspace = root.appendingPathComponent("workspace", isDirectory: true)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    try Data("keep".utf8).write(to: workspace.appendingPathComponent("existing.png"))
    let store = TatwoGoalRunStore(directoryURL: root.appendingPathComponent("goals"))
    let contract = try WorkOSFactory.issueDetachedFixtureForTesting(
      mode: .m, scenarioProfileID: "debug", objective: "computer overwrite test", store: store)
    let approvals = TatwoHostApprovalStore(
      directoryURL: root.appendingPathComponent("approvals"), goalRunStore: store)
    let lease = try approvals.issue(
      contractID: contract.contractID,
      workspaceRoot: workspace.path,
      allowedActions: [.computerUse])
    let host = TatwoComputerHost(approvalStore: approvals)

    XCTAssertThrowsError(try host.execute(
      contractID: contract.contractID,
      leaseID: lease.id,
      workspaceRoot: workspace.path,
      action: .screenshot,
      value: "existing.png")) { error in
        XCTAssertEqual(error as? TatwoHostExecutorError, .protectedTarget)
      }
    XCTAssertEqual(
      try String(contentsOf: workspace.appendingPathComponent("existing.png"), encoding: .utf8),
      "keep")
  }
  #endif
}
