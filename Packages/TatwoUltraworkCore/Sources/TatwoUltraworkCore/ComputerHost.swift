import Foundation
#if os(macOS)
import AppKit
import ApplicationServices
import CoreGraphics
#endif

public enum TatwoComputerActionKind: String, Codable, Sendable, CaseIterable {
  case openApp = "open_app"
  case activateApp = "activate_app"
  case typeText = "type_text"
  case pressKey = "press_key"
  case screenshot
  case mouseMove = "mouse_move"
  case mouseClick = "mouse_click"
  case mouseDoubleClick = "mouse_double_click"
  case scroll
}

public struct TatwoComputerActionV1: Codable, Sendable, Equatable {
  public let schema: String
  public let action: TatwoComputerActionKind
  public let value: String

  public init(
    schema: String = "TatwoComputerActionV1",
    action: TatwoComputerActionKind,
    value: String = ""
  ) {
    self.schema = schema
    self.action = action
    self.value = value
  }
}

public struct TatwoComputerHostStatusV1: Codable, Sendable, Equatable {
  public let schema: String
  public let backend: String
  public let accessibilityGranted: Bool
  public let screenRecordingGranted: Bool
  public let supportedActions: [TatwoComputerActionKind]
  public let requiresContractAndComputerUseLease: Bool

  public init(
    schema: String = "TatwoComputerHostStatusV1",
    backend: String,
    accessibilityGranted: Bool,
    screenRecordingGranted: Bool,
    supportedActions: [TatwoComputerActionKind] = TatwoComputerActionKind.allCases,
    requiresContractAndComputerUseLease: Bool = true
  ) {
    self.schema = schema
    self.backend = backend
    self.accessibilityGranted = accessibilityGranted
    self.screenRecordingGranted = screenRecordingGranted
    self.supportedActions = supportedActions
    self.requiresContractAndComputerUseLease = requiresContractAndComputerUseLease
  }
}

public enum TatwoComputerHostPermission: String, Codable, Sendable, Equatable {
  case accessibility
  case screenRecording = "screen_recording"

  public var systemSettingsURL: URL? {
    switch self {
    case .accessibility:
      URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    case .screenRecording:
      URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }
  }
}

public struct TatwoComputerHostReceiptV1: Codable, Sendable, Equatable {
  public let schema: String
  public let ok: Bool
  public let action: TatwoComputerActionKind
  public let result: String
  public let artifactRelativePath: String?
  public let hostMutationPerformed: Bool

  public init(
    schema: String = "TatwoComputerHostReceiptV1",
    ok: Bool,
    action: TatwoComputerActionKind,
    result: String,
    artifactRelativePath: String? = nil,
    hostMutationPerformed: Bool
  ) {
    self.schema = schema
    self.ok = ok
    self.action = action
    self.result = TatwoPrivacyRedactor.redacted(result)
    self.artifactRelativePath = artifactRelativePath
    self.hostMutationPerformed = hostMutationPerformed
  }
}

public enum TatwoComputerApprovalDenial: String, Codable, Sendable, Equatable {
  case userRequestMissing = "user_request_missing"
  case contractMissing = "contract_missing"
  case systemPermissionMissing = "system_permission_missing"
}

public enum TatwoComputerApprovalDecision: Codable, Sendable, Equatable {
  case allowedOnce
  case denied(TatwoComputerApprovalDenial)
}

public enum TatwoComputerHostTurnRoute: String, Codable, Sendable, Equatable {
  case none
  case mcp
  case embeddedIntent = "embedded_intent"
}

public enum TatwoComputerHostTurnRoutingPolicy {
  public static func select(
    userRequestedComputerUse: Bool,
    isChatMode: Bool,
    isPlanMode: Bool,
    route: TatwoChatRouteProfile
  ) -> TatwoComputerHostTurnRoute {
    guard userRequestedComputerUse, isChatMode, !isPlanMode else {
      return .none
    }
    if route.engine == .claude, route.canonicalModelSlug != "fable-5" {
      return .mcp
    }
    return .embeddedIntent
  }
}

public enum TatwoComputerApprovalPolicy {
  public static let policyID = "macos_permission_internal_lease_visible_intent_single_path"

  public static func evaluate(
    userRequestedComputerUse: Bool,
    hasValidContract: Bool,
    requiredSystemPermissionGranted: Bool
  ) -> TatwoComputerApprovalDecision {
    guard userRequestedComputerUse else {
      return .denied(.userRequestMissing)
    }
    guard hasValidContract else {
      return .denied(.contractMissing)
    }
    guard requiredSystemPermissionGranted else {
      return .denied(.systemPermissionMissing)
    }
    return .allowedOnce
  }
}

public enum TatwoComputerToolIntentParser {
  private static let prefix = "<TATWO_COMPUTER_ACTION>"
  private static let suffix = "</TATWO_COMPUTER_ACTION>"

  public static func parse(_ text: String) -> TatwoComputerActionV1? {
    guard text.components(separatedBy: prefix).count == 2,
      text.components(separatedBy: suffix).count == 2
    else { return nil }
    guard let start = text.range(of: prefix),
      let end = text.range(of: suffix, range: start.upperBound..<text.endIndex)
    else { return nil }
    let payload = text[start.upperBound..<end.lowerBound]
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let data = payload.data(using: .utf8) else { return nil }
    guard let action = try? JSONDecoder().decode(TatwoComputerActionV1.self, from: data),
      action.schema == "TatwoComputerActionV1"
    else { return nil }
    return action
  }

  public static func removingIntent(from text: String) -> String {
    guard let start = text.range(of: prefix),
      let end = text.range(of: suffix, range: start.upperBound..<text.endIndex)
    else { return text }
    var copy = text
    copy.removeSubrange(start.lowerBound..<end.upperBound)
    return copy.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  public static let hiddenPromptContract = """
  [Hidden TATWO Computer Host contract — do not quote]
  When a visible macOS action is genuinely required, emit exactly one machine-readable intent:
  <TATWO_COMPUTER_ACTION>{"schema":"TatwoComputerActionV1","action":"open_app|activate_app|type_text|press_key|screenshot|mouse_move|mouse_click|mouse_double_click|scroll","value":"..."}</TATWO_COMPUTER_ACTION>
  Do not claim the action succeeded. Tatwo OS follows the macos_permission_internal_lease_visible_intent_single_path policy and will execute only after the visible user request, Work OS contract, required macOS privacy permission, and a short-lived internal host lease are all valid. Tatwo OS will return the receipt.
  [/Hidden TATWO Computer Host contract]
  """
}

public enum TatwoComputerPointerParseError: Error, Equatable, LocalizedError, Sendable {
  case invalidValue
  case outOfBounds
  case nonMainDisplay

  public var errorDescription: String? {
    switch self {
    case .invalidValue: "invalid_mouse_value"
    case .outOfBounds: "coordinates_out_of_bounds"
    case .nonMainDisplay: "non_main_display_coordinates"
    }
  }
}

public struct TatwoComputerPointerValue: Equatable, Sendable {
  public let x: Int
  public let y: Int
  public let deltaX: Int
  public let deltaY: Int
}

public struct TatwoComputerDisplayMetrics: Equatable, Sendable {
  public let isMain: Bool
  public let pixelWidth: Int
  public let pixelHeight: Int
  public let backingScaleFactor: Double
  public let quartzX: Double
  public let quartzY: Double
  public let quartzWidth: Double
  public let quartzHeight: Double

  public init(
    isMain: Bool,
    pixelWidth: Int,
    pixelHeight: Int,
    backingScaleFactor: Double,
    quartzX: Double,
    quartzY: Double,
    quartzWidth: Double,
    quartzHeight: Double
  ) {
    self.isMain = isMain
    self.pixelWidth = pixelWidth
    self.pixelHeight = pixelHeight
    self.backingScaleFactor = backingScaleFactor
    self.quartzX = quartzX
    self.quartzY = quartzY
    self.quartzWidth = quartzWidth
    self.quartzHeight = quartzHeight
  }
}

public struct TatwoComputerQuartzPoint: Equatable, Sendable {
  public let x: Double
  public let y: Double
}

public enum TatwoComputerPointerCodec {
  public static func parsePoint(_ value: String) throws -> TatwoComputerPointerValue {
    let parts = try requirePartCount(value, count: 2)
    return TatwoComputerPointerValue(
      x: try nonNegativeInt(parts[0]),
      y: try nonNegativeInt(parts[1]),
      deltaX: 0,
      deltaY: 0)
  }

  public static func parseScroll(_ value: String) throws -> TatwoComputerPointerValue {
    let parts = try requirePartCount(value, count: 4)
    return TatwoComputerPointerValue(
      x: try nonNegativeInt(parts[0]),
      y: try nonNegativeInt(parts[1]),
      deltaX: try signedInt(parts[2]),
      deltaY: try signedInt(parts[3]))
  }

  public static func quartzPoint(
    pixelX: Int,
    pixelY: Int,
    displays: [TatwoComputerDisplayMetrics]
  ) throws -> TatwoComputerQuartzPoint {
    guard let main = displays.first(where: \.isMain), main.backingScaleFactor > 0 else {
      throw TatwoComputerPointerParseError.outOfBounds
    }
    if pixelX < 0 || pixelY < 0 || pixelX >= main.pixelWidth || pixelY >= main.pixelHeight {
      if displays.contains(where: { !$0.isMain }) {
        throw TatwoComputerPointerParseError.nonMainDisplay
      }
      throw TatwoComputerPointerParseError.outOfBounds
    }
    return TatwoComputerQuartzPoint(
      x: main.quartzX + Double(pixelX) / main.backingScaleFactor,
      y: main.quartzY + Double(pixelY) / main.backingScaleFactor)
  }

  private static func splitStrictIntegers(_ value: String) -> [String] {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.split(separator: ",", omittingEmptySubsequences: false).map {
      String($0).trimmingCharacters(in: .whitespacesAndNewlines)
    }
  }

  private static func nonNegativeInt(_ raw: String) throws -> Int {
    guard raw.contains(where: { $0.isNumber }),
      raw.allSatisfy({ $0.isNumber }),
      let value = Int(raw)
    else { throw TatwoComputerPointerParseError.invalidValue }
    return value
  }

  private static func signedInt(_ raw: String) throws -> Int {
    if raw.hasPrefix("-") {
      let digits = String(raw.dropFirst())
      guard digits.contains(where: { $0.isNumber }),
        digits.allSatisfy({ $0.isNumber }),
        let value = Int(raw)
      else { throw TatwoComputerPointerParseError.invalidValue }
      return value
    }
    return try nonNegativeInt(raw)
  }

  fileprivate static func requirePartCount(_ value: String, count: Int) throws -> [String] {
    let parts = splitStrictIntegers(value)
    guard parts.count == count else {
      throw TatwoComputerPointerParseError.invalidValue
    }
    return parts
  }
}

public struct TatwoComputerKeyStroke: Equatable, Sendable {
  public let virtualKeyCode: UInt16
  public let command: Bool
  public let shift: Bool
  public let option: Bool
  public let control: Bool
}

public enum TatwoComputerKeyCodec {
  public static func parse(_ value: String) -> TatwoComputerKeyStroke? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !trimmed.isEmpty else { return nil }
    let parts = trimmed.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
    guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty }) else { return nil }
    guard let keyPart = parts.last, let code = virtualKeyCode(for: keyPart) else { return nil }
    var command = false
    var shift = false
    var option = false
    var control = false
    for modifier in parts.dropLast() {
      switch modifier {
      case "cmd", "command":
        if command { return nil }
        command = true
      case "shift":
        if shift { return nil }
        shift = true
      case "opt", "option", "alt":
        if option { return nil }
        option = true
      case "ctrl", "control":
        if control { return nil }
        control = true
      default:
        return nil
      }
    }
    return TatwoComputerKeyStroke(
      virtualKeyCode: code,
      command: command,
      shift: shift,
      option: option,
      control: control)
  }

  public static func virtualKeyCode(for value: String) -> UInt16? {
    let key = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let named: [String: UInt16] = [
      "return": 36, "enter": 36, "escape": 53, "tab": 48, "space": 49, "delete": 51,
      "left": 123, "right": 124, "down": 125, "up": 126,
    ]
    if let code = named[key] { return code }
    if key.count == 1, let character = key.unicodeScalars.first {
      let letterCodes: [UnicodeScalar: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19,
        "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29, "o": 31,
        "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
      ]
      return letterCodes[character]
    }
    return nil
  }
}

public struct TatwoComputerHost: Sendable {
  public let approvalStore: TatwoHostApprovalStore

  public init(approvalStore: TatwoHostApprovalStore = .default()) {
    self.approvalStore = approvalStore
  }

  public static func status() -> TatwoComputerHostStatusV1 {
    #if os(macOS)
    TatwoComputerHostStatusV1(
      backend: "tatwo-native-macos",
      accessibilityGranted: AXIsProcessTrusted(),
      screenRecordingGranted: CGPreflightScreenCaptureAccess())
    #else
    TatwoComputerHostStatusV1(
      backend: "unsupported",
      accessibilityGranted: false,
      screenRecordingGranted: false,
      supportedActions: [])
    #endif
  }

  public static func missingPermission(
    for action: TatwoComputerActionKind,
    status: TatwoComputerHostStatusV1 = TatwoComputerHost.status()
  ) -> TatwoComputerHostPermission? {
    switch action {
    case .openApp:
      return nil
    case .activateApp, .typeText, .pressKey,
      .mouseMove, .mouseClick, .mouseDoubleClick, .scroll:
      return status.accessibilityGranted ? nil : .accessibility
    case .screenshot:
      return status.screenRecordingGranted ? nil : .screenRecording
    }
  }

  public static func requestSystemPermission(_ permission: TatwoComputerHostPermission) -> Bool {
    #if os(macOS)
    switch permission {
    case .accessibility:
      let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
      return AXIsProcessTrustedWithOptions(options)
    case .screenRecording:
      return CGRequestScreenCaptureAccess()
    }
    #else
    return false
    #endif
  }

  #if os(macOS)
  public func execute(
    contractID: String,
    leaseID: String,
    workspaceRoot: String,
    action: TatwoComputerActionKind,
    value: String
  ) throws -> TatwoComputerHostReceiptV1 {
    let gate = TatwoWorkOSChokepoint.authorize(
      contractID: contractID, action: "tatwo.computer.\(action.rawValue)",
      store: approvalStore.goalRunStore)
    guard gate.ok else { throw TatwoHostExecutorError.contractDenied(gate.code) }
    let lease = try approvalStore.require(
      id: leaseID,
      contractID: contractID,
      workspaceRoot: workspaceRoot,
      action: .computerUse,
      argumentDigest: TatwoHostOperationAuthorizationV1.argumentDigest(
        action: .computerUse,
        components: [action.rawValue, value]))
    defer { try? approvalStore.revoke(id: leaseID) }
    if lease.isRevisionBound, let bounds = lease.resourceBounds {
      guard UInt64(value.utf8.count) <= bounds.maxOutputBytes else {
        throw TatwoHostExecutorError.resourceLimitExceeded("output_bytes")
      }
      if [.openApp, .activateApp, .screenshot].contains(action) {
        guard bounds.maxDurationSeconds >= 20 else {
          throw TatwoHostExecutorError.resourceLimitExceeded("duration")
        }
      }
    }

    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    let process = Process()
    var artifactRelativePath: String?
    switch action {
    case .openApp:
      try validateShortValue(trimmed)
      process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
      process.arguments = ["-a", trimmed]
    case .activateApp:
      try requireAccessibility()
      try validateShortValue(trimmed)
      process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
      process.arguments = ["-a", trimmed]
    case .typeText:
      try requireAccessibility()
      guard !value.isEmpty, value.count <= 16_384 else {
        throw TatwoHostExecutorError.commandDenied
      }
      try Self.postUnicodeText(value)
      return TatwoComputerHostReceiptV1(
        ok: true, action: action, result: "completed", hostMutationPerformed: true)
    case .pressKey:
      try requireAccessibility()
      guard let stroke = TatwoComputerKeyCodec.parse(trimmed) else {
        throw TatwoHostExecutorError.commandDenied
      }
      try Self.postKey(stroke)
      return TatwoComputerHostReceiptV1(
        ok: true, action: action, result: "completed", hostMutationPerformed: true)
    case .mouseMove, .mouseClick, .mouseDoubleClick:
      try requireAccessibility()
      let pointer = try TatwoComputerPointerCodec.parsePoint(trimmed)
      let position = try Self.quartzPointForScreenshotPixels(pointer)
      switch action {
      case .mouseMove:
        try Self.postMouse(
          type: .mouseMoved, position: position, button: .left)
      case .mouseClick:
        try Self.postMouseClick(position: position, count: 1)
      case .mouseDoubleClick:
        try Self.postMouseClick(position: position, count: 2)
      default:
        throw TatwoHostExecutorError.commandDenied
      }
      return TatwoComputerHostReceiptV1(
        ok: true, action: action, result: "completed", hostMutationPerformed: true)
    case .scroll:
      try requireAccessibility()
      let pointer = try TatwoComputerPointerCodec.parseScroll(trimmed)
      let position = try Self.quartzPointForScreenshotPixels(pointer)
      try Self.postMouse(type: .mouseMoved, position: position, button: .left)
      try Self.postScroll(deltaX: pointer.deltaX, deltaY: pointer.deltaY)
      return TatwoComputerHostReceiptV1(
        ok: true, action: action, result: "completed", hostMutationPerformed: true)
    case .screenshot:
      let relative = trimmed.isEmpty
        ? "tatwo-computer-\(UUID().uuidString.lowercased()).png"
        : trimmed
      let target = try safeScreenshotTarget(
        workspaceRoot: workspaceRoot, relativePath: relative)
      try enforceScreenshotTarget(target, lease: lease)
      guard !FileManager.default.fileExists(atPath: target.path) else {
        throw TatwoHostExecutorError.protectedTarget
      }
      guard CGPreflightScreenCaptureAccess() else {
        throw TatwoHostExecutorError.permissionDenied("screen_recording")
      }
      try FileManager.default.createDirectory(
        at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
      process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
      process.arguments = ["-x", target.path]
      artifactRelativePath = relative
    }
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    process.standardInput = FileHandle.nullDevice
    try process.run()
    let processID = process.processIdentifier
    _ = Darwin.setpgid(processID, processID)
    let deadline = Date().addingTimeInterval(20)
    while process.isRunning, Date() < deadline {
      Thread.sleep(forTimeInterval: 0.05)
    }
    // Negative pids signal a process group, so a pid of 0 here would signal our own
    // group and take down the session. isRunning should already rule that out; the
    // guard is here because the failure mode is unrecoverable if it ever does not.
    if process.isRunning, processID > 1 {
      _ = Darwin.kill(-processID, SIGTERM)
      Thread.sleep(forTimeInterval: 0.2)
      if process.isRunning { _ = Darwin.kill(-processID, SIGKILL) }
    }
    process.waitUntilExit()
    let output = String(
      decoding: pipe.fileHandleForReading.readDataToEndOfFile().suffix(64 * 1024),
      as: UTF8.self)
    return TatwoComputerHostReceiptV1(
      ok: process.terminationStatus == 0,
      action: action,
      result: process.terminationStatus == 0
        ? (output.isEmpty ? "completed" : output)
        : (output.isEmpty ? "failed:\(process.terminationStatus)" : output),
      artifactRelativePath: artifactRelativePath,
      hostMutationPerformed: true)
  }

  private func requireAccessibility() throws {
    guard AXIsProcessTrusted() else {
      throw TatwoHostExecutorError.permissionDenied("accessibility")
    }
  }

  private func validateShortValue(_ value: String) throws {
    guard !value.isEmpty, value.count <= 256,
      !value.contains("\n"), !value.contains("\r"), !value.contains("\0")
    else { throw TatwoHostExecutorError.commandDenied }
  }

  private func safeScreenshotTarget(
    workspaceRoot: String,
    relativePath: String
  ) throws -> URL {
    guard !relativePath.hasPrefix("/"),
      !relativePath.split(separator: "/").contains(".."),
      ["png", "jpg", "jpeg"].contains(
        URL(fileURLWithPath: relativePath).pathExtension.lowercased())
    else { throw TatwoHostExecutorError.invalidRelativePath }
    let root = URL(fileURLWithPath: workspaceRoot, isDirectory: true).standardizedFileURL
    let target = root.appendingPathComponent(relativePath).standardizedFileURL
    guard target.path.hasPrefix(root.path + "/") else {
      throw TatwoHostExecutorError.pathDenied
    }
    if (try? target.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
      throw TatwoHostExecutorError.pathDenied
    }
    var cursor = target.deletingLastPathComponent()
    while cursor.path.hasPrefix(root.path), cursor.path != root.path {
      if (try? cursor.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
        throw TatwoHostExecutorError.pathDenied
      }
      cursor.deleteLastPathComponent()
    }
    return target
  }

  private func enforceScreenshotTarget(
    _ target: URL,
    lease: TatwoHostApprovalLeaseV1
  ) throws {
    guard lease.isRevisionBound else { return }
    guard let bounds = lease.resourceBounds,
      bounds.maxFileCount >= 1
    else {
      throw TatwoHostExecutorError.resourceLimitExceeded("file_count")
    }
    guard lease.outputRoots?.contains(where: { rawRoot in
      let root = URL(fileURLWithPath: rawRoot, isDirectory: true)
        .standardizedFileURL.resolvingSymlinksInPath().path
      return target.path == root || target.path.hasPrefix(root + "/")
    }) == true
    else { throw TatwoHostExecutorError.approvalScopeMismatch }
  }

  private static func quartzPointForScreenshotPixels(
    _ pointer: TatwoComputerPointerValue
  ) throws -> CGPoint {
    let quartz = try TatwoComputerPointerCodec.quartzPoint(
      pixelX: pointer.x,
      pixelY: pointer.y,
      displays: liveDisplayMetrics())
    return CGPoint(x: quartz.x, y: quartz.y)
  }

  private static func liveDisplayMetrics() throws -> [TatwoComputerDisplayMetrics] {
    let screens = NSScreen.screens
    guard let main = NSScreen.main ?? screens.first else {
      throw TatwoComputerPointerParseError.outOfBounds
    }
    return screens.map { screen in
      let scale = screen.backingScaleFactor
      let frame = screen.frame
      let mainFrame = main.frame
      let quartzX = frame.origin.x - mainFrame.origin.x
      let quartzY =
        (mainFrame.origin.y + mainFrame.height) - (frame.origin.y + frame.height)
      return TatwoComputerDisplayMetrics(
        isMain: screen === main,
        pixelWidth: Int((frame.width * scale).rounded()),
        pixelHeight: Int((frame.height * scale).rounded()),
        backingScaleFactor: Double(scale),
        quartzX: Double(quartzX),
        quartzY: Double(quartzY),
        quartzWidth: Double(frame.width),
        quartzHeight: Double(frame.height))
    }
  }

  private static func postKey(_ stroke: TatwoComputerKeyStroke) throws {
    let code = CGKeyCode(stroke.virtualKeyCode)
    var flags: CGEventFlags = []
    if stroke.command { flags.insert(.maskCommand) }
    if stroke.shift { flags.insert(.maskShift) }
    if stroke.option { flags.insert(.maskAlternate) }
    if stroke.control { flags.insert(.maskControl) }
    guard let source = CGEventSource(stateID: .hidSystemState),
      let keyDown = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
      let keyUp = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
    else {
      throw TatwoHostExecutorError.commandDenied
    }
    keyDown.flags = flags
    keyUp.flags = flags
    keyDown.post(tap: .cghidEventTap)
    keyUp.post(tap: .cghidEventTap)
  }

  private static func postMouse(
    type: CGEventType,
    position: CGPoint,
    button: CGMouseButton,
    clickState: Int64? = nil
  ) throws {
    guard let source = CGEventSource(stateID: .hidSystemState),
      let event = CGEvent(
        mouseEventSource: source,
        mouseType: type,
        mouseCursorPosition: position,
        mouseButton: button)
    else {
      throw TatwoHostExecutorError.commandDenied
    }
    if let clickState {
      event.setIntegerValueField(.mouseEventClickState, value: clickState)
    }
    event.post(tap: .cghidEventTap)
  }

  private static func postMouseClick(position: CGPoint, count: Int64) throws {
    try postMouse(type: .mouseMoved, position: position, button: .left)
    for clickState in 1...count {
      try postMouse(
        type: .leftMouseDown, position: position, button: .left, clickState: clickState)
      try postMouse(
        type: .leftMouseUp, position: position, button: .left, clickState: clickState)
    }
  }

  private static func postScroll(deltaX: Int, deltaY: Int) throws {
    guard let source = CGEventSource(stateID: .hidSystemState),
      let event = CGEvent(
        scrollWheelEvent2Source: source,
        units: .pixel,
        wheelCount: 2,
        wheel1: Int32(clamping: deltaY),
        wheel2: Int32(clamping: deltaX),
        wheel3: 0)
    else {
      throw TatwoHostExecutorError.commandDenied
    }
    event.post(tap: .cghidEventTap)
  }

  private static func postUnicodeText(_ value: String) throws {
    guard let source = CGEventSource(stateID: .hidSystemState) else {
      throw TatwoHostExecutorError.commandDenied
    }
    let units = Array(value.utf16)
    var offset = 0
    while offset < units.count {
      let end = min(offset + 20, units.count)
      let chunk = Array(units[offset..<end])
      guard
        let keyDown = CGEvent(
          keyboardEventSource: source, virtualKey: 0, keyDown: true),
        let keyUp = CGEvent(
          keyboardEventSource: source, virtualKey: 0, keyDown: false)
      else {
        throw TatwoHostExecutorError.commandDenied
      }
      chunk.withUnsafeBufferPointer { buffer in
        guard let baseAddress = buffer.baseAddress else { return }
        keyDown.keyboardSetUnicodeString(
          stringLength: buffer.count, unicodeString: baseAddress)
        keyUp.keyboardSetUnicodeString(
          stringLength: buffer.count, unicodeString: baseAddress)
      }
      keyDown.post(tap: .cghidEventTap)
      keyUp.post(tap: .cghidEventTap)
      offset = end
    }
  }
  #endif
}
