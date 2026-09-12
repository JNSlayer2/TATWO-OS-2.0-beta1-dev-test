import Foundation
import XCTest

@testable import TatwoUltraworkCore

final class DeviceMutualControlS1Tests: XCTestCase {
  private let testEnvironment = [TatwoLoopJobChannelTrust.testModeEnvKey: "1"]
  private let producedAt = Date(timeIntervalSince1970: 1_800_000_000)

  // MARK: - Fixtures

  private func listDirDescriptor(
    risk: TatwoMutualControlRiskLevelV1 = .normal,
    highRisk: TatwoMutualControlHighRiskCategoryV1? = nil,
    enabled: Bool = true,
    executable: String = "/bin/ls",
    argvTemplate: [String] = ["-la", "{path}"],
    pathRoots: [String] = ["/Users/shared/inbox", "/tmp/mutual-control"]
  ) -> TatwoDeviceCapabilityDescriptorV1 {
    TatwoDeviceCapabilityDescriptorV1(
      templateID: "fs.list_dir",
      displayName: "List directory",
      description: "argv-only directory listing",
      executable: executable,
      argvTemplate: argvTemplate,
      paramSlots: [
        TatwoMutualControlParamSlotV1(
          name: "path",
          constraint: .pathPrefix(pathRoots))
      ],
      resourceLimits: TatwoMutualControlResourceLimitsV1(
        timeoutSec: 30,
        maxOutputBytes: 64_000),
      riskLevel: risk,
      highRiskCategory: highRisk,
      sideEffectClass: .readOnly,
      enabled: enabled)
  }

  private func deleteDescriptor() -> TatwoDeviceCapabilityDescriptorV1 {
    TatwoDeviceCapabilityDescriptorV1(
      templateID: "fs.trash_path",
      displayName: "Trash path",
      executable: "/usr/bin/trash",
      argvTemplate: ["{path}"],
      paramSlots: [
        TatwoMutualControlParamSlotV1(
          name: "path",
          constraint: .pathPrefix(["/Users/shared/inbox"]))
      ],
      resourceLimits: TatwoMutualControlResourceLimitsV1(
        timeoutSec: 60,
        maxOutputBytes: 8_192),
      riskLevel: .highRisk,
      highRiskCategory: .delete,
      sideEffectClass: .localMutable,
      enabled: true)
  }

  private func modeEnumDescriptor() -> TatwoDeviceCapabilityDescriptorV1 {
    TatwoDeviceCapabilityDescriptorV1(
      templateID: "tatwo.doctor.json",
      executable: "/usr/local/bin/tatwo-ultrawork",
      argvTemplate: ["doctor", "--format", "{format}"],
      paramSlots: [
        TatwoMutualControlParamSlotV1(
          name: "format",
          constraint: .enumValues(["json", "text"]))
      ],
      resourceLimits: TatwoMutualControlResourceLimitsV1(
        timeoutSec: 15,
        maxOutputBytes: 32_000),
      riskLevel: .normal,
      sideEffectClass: .readOnly)
  }

  private func invocation(
    templateID: String,
    params: [String: String],
    capabilityVersion: UInt64 = 1,
    approvalID: String? = nil,
    purpose: String = TatwoMutualControlPurposeV1.deviceMutualControlInvoke.rawValue,
    requestedTimeoutSec: TimeInterval? = nil,
    requestedMaxOutputBytes: Int? = nil,
    leaseDomainBinding: TatwoLeaseDomainBindingV1 = .none(
      justification: "test target is outside any lease domain")
  ) -> TatwoMutualControlInvocationV1 {
    TatwoMutualControlInvocationV1(
      purpose: purpose,
      logicalControlID: "logical-mc-1",
      jobID: "job-mc-1",
      dispatchNonce: "nonce-mc-1",
      sourceDeviceID: "source-a",
      operatorPrincipalID: "operator-alice",
      targetDeviceID: "target-b",
      templateID: templateID,
      capabilityVersion: capabilityVersion,
      params: params,
      approvalID: approvalID,
      requestedTimeoutSec: requestedTimeoutSec,
      requestedMaxOutputBytes: requestedMaxOutputBytes,
      leaseDomainBinding: leaseDomainBinding)
  }

  private func makeTrust(deviceID: String = "target-b") throws -> TatwoLoopJobChannelTrust {
    try TatwoLoopJobChannelTrust.enroll(
      deviceID: deviceID,
      privateKeyStore: MutualControlMemoryPrivateKeyStore(),
      pinnedAt: producedAt,
      environment: testEnvironment)
  }

  private func validateSigned(
    invocation: TatwoMutualControlInvocationV1,
    descriptor: TatwoDeviceCapabilityDescriptorV1,
    capabilityVersion: UInt64 = 1
  ) throws -> TatwoMutualControlValidationResultV1 {
    let trust = try makeTrust()
    let manifest = try TatwoDeviceCapabilityManifestV1.make(
      targetDeviceID: "target-b",
      capabilityVersion: capabilityVersion,
      descriptors: [descriptor],
      producedAt: producedAt,
      trust: trust)
    return TatwoMutualControlValidatorV1.validate(
      invocation: invocation,
      manifest: manifest,
      pinnedIdentity: trust.localIdentity)
  }

  // MARK: - Whitelist pass

  func testWhitelistPathPrefixPassesAndResolvesArgv() throws {
    let descriptor = listDirDescriptor()
    let inv = invocation(
      templateID: "fs.list_dir",
      params: ["path": "/Users/shared/inbox/report"])
    let result = try validateSigned(invocation: inv, descriptor: descriptor)
    XCTAssertTrue(result.accepted, result.detail ?? "")
    XCTAssertFalse(result.requiresHumanGate)
    XCTAssertEqual(result.resolvedExecutable, "/bin/ls")
    XCTAssertEqual(result.resolvedArgv, ["-la", "/Users/shared/inbox/report"])
    XCTAssertNil(result.errorCode)
    XCTAssertNotNil(result.invokeCanonicalDigest)
  }

  func testWhitelistEnumPasses() throws {
    let result = try validateSigned(
      invocation: invocation(templateID: "tatwo.doctor.json", params: ["format": "json"]),
      descriptor: modeEnumDescriptor())
    XCTAssertTrue(result.accepted, result.detail ?? "")
    XCTAssertEqual(result.resolvedArgv, ["doctor", "--format", "json"])
  }

  func testShellMetacharactersRemainSingleArgvElement() throws {
    // `;` / `$()` / spaces / quotes are literal argv bytes — not shell-interpreted.
    // Path must still satisfy pathPrefix whitelist.
    let descriptor = listDirDescriptor(
      pathRoots: ["/Users/shared/inbox"])
    // Use a path under root that embeds metacharacter-looking segments as path components.
    let path = "/Users/shared/inbox/file;rm -rf"
    let result = try validateSigned(
      invocation: invocation(templateID: "fs.list_dir", params: ["path": path]),
      descriptor: descriptor)
    XCTAssertTrue(result.accepted, result.detail ?? "")
    XCTAssertEqual(result.resolvedArgv?.last, path)
    XCTAssertEqual(result.resolvedArgv?.count, 2)
  }

  // MARK: - Out-of-bounds reject

  func testPathEscapeOutsideAllowedRootsRejected() throws {
    let result = try validateSigned(
      invocation: invocation(
        templateID: "fs.list_dir",
        params: ["path": "/Users/shared/inbox-evil/secret"]),
      descriptor: listDirDescriptor(pathRoots: ["/Users/shared/inbox"]))
    XCTAssertFalse(result.accepted)
    XCTAssertEqual(result.errorCode, .paramInvalid)
  }

  func testEnumOutOfWhitelistRejected() throws {
    let result = try validateSigned(
      invocation: invocation(
        templateID: "tatwo.doctor.json",
        params: ["format": "xml"]),
      descriptor: modeEnumDescriptor())
    XCTAssertFalse(result.accepted)
    XCTAssertEqual(result.errorCode, .paramInvalid)
  }

  func testUnknownParamRejected() throws {
    let result = try validateSigned(
      invocation: invocation(
        templateID: "tatwo.doctor.json",
        params: ["format": "json", "extra": "nope"]),
      descriptor: modeEnumDescriptor())
    XCTAssertFalse(result.accepted)
    XCTAssertEqual(result.errorCode, .paramInvalid)
  }

  func testResourceLimitExceededRejected() throws {
    let result = try validateSigned(
      invocation: invocation(
        templateID: "fs.list_dir",
        params: ["path": "/tmp/mutual-control/a"],
        requestedTimeoutSec: 999),
      descriptor: listDirDescriptor())
    XCTAssertFalse(result.accepted)
    XCTAssertEqual(result.errorCode, .resourceLimit)
  }

  // MARK: - Injection attempts

  func testNULInjectionRejected() throws {
    let nulPath = "/Users/shared/inbox/a\u{0}b"
    let result = try validateSigned(
      invocation: invocation(templateID: "fs.list_dir", params: ["path": nulPath]),
      descriptor: listDirDescriptor())
    XCTAssertFalse(result.accepted)
    XCTAssertEqual(result.errorCode, .injectionRejected)
  }

  func testNewlineInjectionRejected() throws {
    let path = "/Users/shared/inbox/a\nb"
    let result = try validateSigned(
      invocation: invocation(templateID: "fs.list_dir", params: ["path": path]),
      descriptor: listDirDescriptor())
    XCTAssertFalse(result.accepted)
    XCTAssertEqual(result.errorCode, .injectionRejected)
  }

  func testEmbeddedPlaceholderInTemplateRejected() throws {
    let bad = TatwoDeviceCapabilityDescriptorV1(
      templateID: "evil.shellish",
      executable: "/bin/echo",
      argvTemplate: ["prefix-{path}-suffix"],
      paramSlots: [
        TatwoMutualControlParamSlotV1(name: "path", constraint: .enumValues(["x"]))
      ],
      resourceLimits: TatwoMutualControlResourceLimitsV1(timeoutSec: 5, maxOutputBytes: 100))
    let result = try validateSigned(
      invocation: invocation(templateID: "evil.shellish", params: ["path": "x"]),
      descriptor: bad)
    XCTAssertFalse(result.accepted)
    XCTAssertEqual(result.errorCode, .forbiddenShellShape)
  }

  func testShDashCShapeForcesHighRiskGate() throws {
    let bad = TatwoDeviceCapabilityDescriptorV1(
      templateID: "evil.sh",
      executable: "/bin/sh",
      argvTemplate: ["-c", "printf fixed"],
      paramSlots: [],
      resourceLimits: TatwoMutualControlResourceLimitsV1(timeoutSec: 5, maxOutputBytes: 100))
    let result = try validateSigned(
      invocation: invocation(
        templateID: "evil.sh",
        params: [:]),
      descriptor: bad)
    XCTAssertFalse(result.accepted)
    XCTAssertEqual(result.errorCode, .highRiskNoApproval)
    XCTAssertTrue(result.requiresHumanGate)
    XCTAssertEqual(result.highRiskCategory, .interpreter)
    XCTAssertEqual(result.riskLevel, .highRisk)
  }

  func testInterpreterAndSystemRiskShapesOverrideNormalDescriptor() throws {
    let interpreterShapes: [(String, [String])] = [
      ("/bin/sh", ["-c", "printf fixed"]),
      ("/bin/bash", ["-lc", "printf fixed"]),
      ("/bin/zsh", ["--command", "printf fixed"]),
      ("/bin/dash", ["-c", "printf fixed"]),
      ("/usr/bin/env", ["sh", "-c", "printf fixed"]),
      ("/usr/bin/python3", ["-c", "print(1)"]),
      ("/usr/bin/python", ["-c", "print(1)"]),
      ("/usr/bin/node", ["--eval", "console.log(1)"]),
      ("/usr/bin/osascript", ["-e", "return 1"]),
      ("/usr/bin/ruby", ["-e", "puts 1"]),
      ("/usr/bin/perl", ["-e", "print 1"])
    ]
    for (index, shape) in interpreterShapes.enumerated() {
      let descriptor = TatwoDeviceCapabilityDescriptorV1(
        templateID: "risk.interpreter.\(index)",
        executable: shape.0,
        argvTemplate: shape.1,
        paramSlots: [],
        resourceLimits: TatwoMutualControlResourceLimitsV1(
          timeoutSec: 5,
          maxOutputBytes: 100),
        riskLevel: .normal,
        sideEffectClass: .external)
      let result = try validateSigned(
        invocation: invocation(
          templateID: descriptor.templateID,
          params: [:]),
        descriptor: descriptor)
      XCTAssertFalse(result.accepted, shape.0)
      XCTAssertEqual(result.errorCode, .highRiskNoApproval, shape.0)
      XCTAssertTrue(result.requiresHumanGate, shape.0)
      XCTAssertEqual(result.riskLevel, .highRisk, shape.0)
      XCTAssertEqual(result.highRiskCategory, .interpreter, shape.0)
    }

    let systemShapes: [(String, [String], TatwoMutualControlHighRiskCategoryV1)] = [
      ("/bin/rm", ["/usr/local/bin/tool"], .delete),
      ("/bin/mv", ["/System/Library/tool"], .deploy),
      ("/bin/launchctl", [], .systemPermission),
      ("/usr/bin/security", [], .systemPermission),
      ("/usr/bin/codesign", [], .systemPermission),
      ("/usr/sbin/networksetup", [], .systemPermission)
    ]
    for (index, shape) in systemShapes.enumerated() {
      let descriptor = TatwoDeviceCapabilityDescriptorV1(
        templateID: "risk.system.\(index)",
        executable: shape.0,
        argvTemplate: shape.1,
        paramSlots: [],
        resourceLimits: TatwoMutualControlResourceLimitsV1(
          timeoutSec: 5,
          maxOutputBytes: 100),
        riskLevel: .normal,
        sideEffectClass: .external)
      let result = try validateSigned(
        invocation: invocation(
          templateID: descriptor.templateID,
          params: [:]),
        descriptor: descriptor)
      XCTAssertFalse(result.accepted, shape.0)
      XCTAssertEqual(result.errorCode, .highRiskNoApproval, shape.0)
      XCTAssertEqual(result.highRiskCategory, shape.2, shape.0)
    }
  }

  func testUnsignedManifestAndDirectDescriptorAreRejected() throws {
    let descriptor = listDirDescriptor()
    let unsigned = try TatwoDeviceCapabilityManifestV1.make(
      targetDeviceID: "target-b",
      capabilityVersion: 1,
      descriptors: [descriptor],
      producedAt: producedAt)
    let inv = invocation(
      templateID: descriptor.templateID,
      params: ["path": "/tmp/mutual-control/ok"])
    let manifestResult = TatwoMutualControlValidatorV1.validate(
      invocation: inv,
      manifest: unsigned,
      pinnedIdentity: nil)
    XCTAssertFalse(manifestResult.accepted)
    XCTAssertEqual(manifestResult.errorCode, .signatureInvalid)

    let directResult = TatwoMutualControlValidatorV1.validate(
      invocation: inv,
      descriptor: descriptor)
    XCTAssertFalse(directResult.accepted)
    XCTAssertEqual(directResult.errorCode, .signatureInvalid)
  }

  func testArgvBoundsAndRegexComplexityAreBounded() throws {
    let tooMany = TatwoDeviceCapabilityDescriptorV1(
      templateID: "bounds.too-many",
      executable: "/bin/echo",
      argvTemplate: Array(repeating: "x", count: 65),
      paramSlots: [],
      resourceLimits: TatwoMutualControlResourceLimitsV1(
        timeoutSec: 5,
        maxOutputBytes: 100))
    let tooManyResult = try validateSigned(
      invocation: invocation(templateID: tooMany.templateID, params: [:]),
      descriptor: tooMany)
    XCTAssertFalse(tooManyResult.accepted)
    XCTAssertEqual(tooManyResult.errorCode, .resourceLimit)

    let tooLong = TatwoDeviceCapabilityDescriptorV1(
      templateID: "bounds.too-long",
      executable: "/bin/echo",
      argvTemplate: [String(repeating: "x", count: 4 * 1024 + 1)],
      paramSlots: [],
      resourceLimits: TatwoMutualControlResourceLimitsV1(
        timeoutSec: 5,
        maxOutputBytes: 100))
    let tooLongResult = try validateSigned(
      invocation: invocation(templateID: tooLong.templateID, params: [:]),
      descriptor: tooLong)
    XCTAssertFalse(tooLongResult.accepted)
    XCTAssertEqual(tooLongResult.errorCode, .resourceLimit)

    for pattern in ["((a+))+", String(repeating: "a", count: 513)] {
      let regexDescriptor = TatwoDeviceCapabilityDescriptorV1(
        templateID: "bounds.regex.\(pattern.count)",
        executable: "/bin/echo",
        argvTemplate: ["{value}"],
        paramSlots: [
          TatwoMutualControlParamSlotV1(
            name: "value",
            constraint: .regex(pattern))
        ],
        resourceLimits: TatwoMutualControlResourceLimitsV1(
          timeoutSec: 5,
          maxOutputBytes: 100))
      let result = try validateSigned(
        invocation: invocation(
          templateID: regexDescriptor.templateID,
          params: ["value": "aaa"]),
        descriptor: regexDescriptor)
      XCTAssertFalse(result.accepted, pattern)
      XCTAssertEqual(result.errorCode, .resourceLimit, pattern)
    }
  }

  func testNFCNormalizationAppliesToWhitelistComparisons() throws {
    let descriptor = TatwoDeviceCapabilityDescriptorV1(
      templateID: "nfc.enum",
      executable: "/bin/echo",
      argvTemplate: ["{value}"],
      paramSlots: [
        TatwoMutualControlParamSlotV1(
          name: "value",
          constraint: .enumValues(["cafe\u{301}"]))
      ],
      resourceLimits: TatwoMutualControlResourceLimitsV1(
        timeoutSec: 5,
        maxOutputBytes: 100))
    let result = try validateSigned(
      invocation: invocation(
        templateID: "nfc.enum",
        params: ["value": "café"]),
      descriptor: descriptor)
    XCTAssertTrue(result.accepted, result.detail ?? "")
    XCTAssertEqual(result.resolvedArgv, ["café"])
  }

  // MARK: - Empty list = uncontrollable

  func testEmptyManifestRejectsAllTemplates() throws {
    let trust = try makeTrust()
    let empty = try TatwoDeviceCapabilityManifestV1.make(
      targetDeviceID: "target-b",
      capabilityVersion: 1,
      descriptors: [],
      producedAt: producedAt,
      trust: trust)
    XCTAssertTrue(empty.isEmpty)

    let result = TatwoMutualControlValidatorV1.validate(
      invocation: invocation(
        templateID: "fs.list_dir",
        params: ["path": "/Users/shared/inbox/a"]),
      manifest: empty,
      pinnedIdentity: trust.localIdentity,
      requireSignature: true)
    XCTAssertFalse(result.accepted)
    XCTAssertEqual(result.errorCode, .capabilityEmpty)
  }

  // MARK: - High risk requires human gate

  func testHighRiskForcesRequiresHumanGateAndRejectsWithoutApproval() throws {
    let trust = try makeTrust()
    let manifest = try TatwoDeviceCapabilityManifestV1.make(
      targetDeviceID: "target-b",
      capabilityVersion: 2,
      descriptors: [deleteDescriptor()],
      producedAt: producedAt,
      trust: trust)

    let noApproval = TatwoMutualControlValidatorV1.validate(
      invocation: invocation(
        templateID: "fs.trash_path",
        params: ["path": "/Users/shared/inbox/old"],
        capabilityVersion: 2),
      manifest: manifest,
      pinnedIdentity: trust.localIdentity,
      requireSignature: true)
    XCTAssertFalse(noApproval.accepted)
    XCTAssertTrue(noApproval.requiresHumanGate)
    XCTAssertEqual(noApproval.errorCode, .highRiskNoApproval)
    XCTAssertEqual(noApproval.highRiskCategory, .delete)
    XCTAssertEqual(noApproval.riskLevel, .highRisk)

    let withApproval = TatwoMutualControlValidatorV1.validate(
      invocation: invocation(
        templateID: "fs.trash_path",
        params: ["path": "/Users/shared/inbox/old"],
        capabilityVersion: 2,
        approvalID: "approval-once-1"),
      manifest: manifest,
      pinnedIdentity: trust.localIdentity,
      requireSignature: true)
    XCTAssertTrue(withApproval.accepted, withApproval.detail ?? "")
    XCTAssertTrue(withApproval.requiresHumanGate, "high_risk must keep requiresHumanGate even when approved")
  }

  func testAllHighRiskCategoriesForbidStandingAuthorization() {
    for category in TatwoMutualControlHighRiskCategoryV1.allCases {
      XCTAssertTrue(category.requiresHumanGate, category.rawValue)
      XCTAssertTrue(category.forbidsStandingAuthorization, category.rawValue)
    }
  }

  func testSovereigntyTemplateRedirectsToHandoffPlane() throws {
    let trust = try makeTrust()
    let sovereignty = TatwoDeviceCapabilityDescriptorV1(
      templateID: "device.transfer_origin",
      executable: "/usr/bin/true",
      argvTemplate: [],
      paramSlots: [],
      resourceLimits: TatwoMutualControlResourceLimitsV1(timeoutSec: 5, maxOutputBytes: 64),
      riskLevel: .highRisk,
      highRiskCategory: .sovereignty,
      sideEffectClass: .external)
    let manifest = try TatwoDeviceCapabilityManifestV1.make(
      targetDeviceID: "target-b",
      capabilityVersion: 1,
      descriptors: [sovereignty],
      producedAt: producedAt,
      trust: trust)
    let result = TatwoMutualControlValidatorV1.validate(
      invocation: invocation(
        templateID: "device.transfer_origin",
        params: [:],
        approvalID: "approval-x"),
      manifest: manifest,
      pinnedIdentity: trust.localIdentity,
      requireSignature: true)
    XCTAssertFalse(result.accepted)
    XCTAssertEqual(result.errorCode, .useHandoffPlane)
    XCTAssertTrue(result.requiresHumanGate)
  }

  // MARK: - Signature / version

  func testManifestSignatureHappyPath() throws {
    let trust = try makeTrust()
    let manifest = try TatwoDeviceCapabilityManifestV1.make(
      targetDeviceID: "target-b",
      capabilityVersion: 3,
      descriptors: [listDirDescriptor()],
      producedAt: producedAt,
      trust: trust)
    XCTAssertNotNil(manifest.producerSignature)
    XCTAssertEqual(manifest.manifestDigest, try manifest.computeManifestDigest())

    let result = TatwoMutualControlValidatorV1.validate(
      invocation: invocation(
        templateID: "fs.list_dir",
        params: ["path": "/tmp/mutual-control/ok"],
        capabilityVersion: 3),
      manifest: manifest,
      pinnedIdentity: trust.localIdentity,
      requireSignature: true)
    XCTAssertTrue(result.accepted, result.detail ?? "")
  }

  func testSignatureTamperRejected() throws {
    let trust = try makeTrust()
    let manifest = try TatwoDeviceCapabilityManifestV1.make(
      targetDeviceID: "target-b",
      capabilityVersion: 1,
      descriptors: [listDirDescriptor()],
      producedAt: producedAt,
      trust: trust)
    let sig = try XCTUnwrap(manifest.producerSignature)
    let tamperedSig = TatwoDeviceSignatureV1(
      purpose: sig.purpose,
      deviceID: sig.deviceID,
      keyID: sig.keyID,
      keyGeneration: sig.keyGeneration,
      payloadDigest: sig.payloadDigest,
      signedAt: sig.signedAt,
      signature: String(repeating: "A", count: 64).data(using: .utf8)!.base64EncodedString())
    let tampered = TatwoDeviceCapabilityManifestV1(
      targetDeviceID: manifest.targetDeviceID,
      capabilityVersion: manifest.capabilityVersion,
      descriptors: manifest.descriptors,
      producedAt: manifest.producedAt,
      freshUntil: manifest.freshUntil,
      manifestDigest: manifest.manifestDigest,
      producerSignature: tamperedSig,
      signingKeyFingerprint: manifest.signingKeyFingerprint,
      supersedesVersion: manifest.supersedesVersion)

    let result = TatwoMutualControlValidatorV1.validate(
      invocation: invocation(
        templateID: "fs.list_dir",
        params: ["path": "/tmp/mutual-control/ok"]),
      manifest: tampered,
      pinnedIdentity: trust.localIdentity,
      requireSignature: true)
    XCTAssertFalse(result.accepted)
    XCTAssertEqual(result.errorCode, .signatureInvalid)
  }

  func testManifestDigestTamperRejected() throws {
    let trust = try makeTrust()
    let manifest = try TatwoDeviceCapabilityManifestV1.make(
      targetDeviceID: "target-b",
      capabilityVersion: 1,
      descriptors: [listDirDescriptor()],
      producedAt: producedAt,
      trust: trust)
    let tampered = TatwoDeviceCapabilityManifestV1(
      targetDeviceID: manifest.targetDeviceID,
      capabilityVersion: manifest.capabilityVersion,
      descriptors: manifest.descriptors,
      producedAt: manifest.producedAt,
      freshUntil: manifest.freshUntil,
      manifestDigest: "sha256:" + String(repeating: "0", count: 64),
      producerSignature: manifest.producerSignature,
      signingKeyFingerprint: manifest.signingKeyFingerprint,
      supersedesVersion: manifest.supersedesVersion)
    let result = TatwoMutualControlValidatorV1.validate(
      invocation: invocation(
        templateID: "fs.list_dir",
        params: ["path": "/tmp/mutual-control/ok"]),
      manifest: tampered,
      pinnedIdentity: trust.localIdentity,
      requireSignature: true)
    XCTAssertFalse(result.accepted)
    XCTAssertEqual(result.errorCode, .signatureInvalid)
  }

  func testCapabilityVersionMismatchRejected() throws {
    let trust = try makeTrust()
    let manifest = try TatwoDeviceCapabilityManifestV1.make(
      targetDeviceID: "target-b",
      capabilityVersion: 5,
      descriptors: [listDirDescriptor()],
      producedAt: producedAt,
      trust: trust)
    let result = TatwoMutualControlValidatorV1.validate(
      invocation: invocation(
        templateID: "fs.list_dir",
        params: ["path": "/tmp/mutual-control/ok"],
        capabilityVersion: 4),
      manifest: manifest,
      pinnedIdentity: trust.localIdentity,
      requireSignature: true)
    XCTAssertFalse(result.accepted)
    XCTAssertEqual(result.errorCode, .capabilityVersionMismatch)
  }

  func testTemplateNotFoundRejected() throws {
    let trust = try makeTrust()
    let manifest = try TatwoDeviceCapabilityManifestV1.make(
      targetDeviceID: "target-b",
      capabilityVersion: 1,
      descriptors: [listDirDescriptor()],
      producedAt: producedAt,
      trust: trust)
    let result = TatwoMutualControlValidatorV1.validate(
      invocation: invocation(
        templateID: "fs.not_listed",
        params: [:]),
      manifest: manifest,
      pinnedIdentity: trust.localIdentity,
      requireSignature: true)
    XCTAssertFalse(result.accepted)
    XCTAssertEqual(result.errorCode, .templateNotFound)
  }

  // MARK: - Receipt structure

  func testRejectReceiptCarriesAttemptBindingAndGateFlag() throws {
    let descriptor = deleteDescriptor()
    let inv = invocation(
      templateID: "fs.trash_path",
      params: ["path": "/Users/shared/inbox/old"])
    let validation = try validateSigned(invocation: inv, descriptor: descriptor)
    XCTAssertEqual(validation.errorCode, .highRiskNoApproval)
    let receipt = try TatwoMutualControlReceiptV1.makeRejected(
      invocation: inv,
      validation: validation,
      startedAt: producedAt,
      endedAt: producedAt.addingTimeInterval(1))
    XCTAssertEqual(receipt.status, .rejected)
    XCTAssertEqual(receipt.jobID, inv.jobID)
    XCTAssertEqual(receipt.dispatchNonce, inv.dispatchNonce)
    XCTAssertEqual(receipt.logicalControlID, inv.logicalControlID)
    XCTAssertFalse(receipt.invokeCanonicalDigest.isEmpty)
    XCTAssertEqual(receipt.sourceDeviceID, "source-a")
    XCTAssertEqual(receipt.operatorPrincipalID, "operator-alice")
    XCTAssertEqual(receipt.targetDeviceID, "target-b")
    XCTAssertTrue(receipt.requiresHumanGate)
    XCTAssertEqual(receipt.rejectCode, .highRiskNoApproval)
    XCTAssertEqual(receipt.riskLevel, .highRisk)
    XCTAssertEqual(receipt.highRiskCategory, .delete)
    XCTAssertEqual(receipt.actualArgv, ["/Users/shared/inbox/old"])
  }

  func testPurposeMismatchFleetRedirect() throws {
    let trust = try makeTrust()
    let manifest = try TatwoDeviceCapabilityManifestV1.make(
      targetDeviceID: "target-b",
      capabilityVersion: 1,
      descriptors: [listDirDescriptor()],
      producedAt: producedAt,
      trust: trust)
    let result = TatwoMutualControlValidatorV1.validate(
      invocation: invocation(
        templateID: "fs.list_dir",
        params: ["path": "/tmp/mutual-control/ok"],
        purpose: "remote_execute_candidate"),
      manifest: manifest,
      pinnedIdentity: trust.localIdentity,
      requireSignature: true)
    XCTAssertFalse(result.accepted)
    XCTAssertEqual(result.errorCode, .useFleetPlane)
  }

  func testDescriptorDigestStableAcrossKeyOrder() throws {
    let a = listDirDescriptor()
    let b = listDirDescriptor()
    XCTAssertEqual(try a.computeDescriptorDigest(), try b.computeDescriptorDigest())
  }
}

// MARK: - Test key store (memory only; no Keychain)

private final class MutualControlMemoryPrivateKeyStore: TatwoDevicePrivateKeyStore, @unchecked Sendable {
  private let lock = NSLock()
  private var keys: [String: Data] = [:]

  func loadPrivateKey(deviceID: String, generation: UInt64) throws -> Data? {
    lock.lock()
    defer { lock.unlock() }
    return keys["\(deviceID)#\(generation)"]
  }

  func storePrivateKey(_ key: Data, deviceID: String, generation: UInt64) throws {
    lock.lock()
    defer { lock.unlock() }
    keys["\(deviceID)#\(generation)"] = key
  }
}
