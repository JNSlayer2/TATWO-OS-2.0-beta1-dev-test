import CryptoKit
import Foundation
import XCTest
#if canImport(Darwin)
import Darwin
#endif

@_spi(TatwoBootstrapRecoveryHost) @testable import TatwoUltraworkCore

#if os(macOS)
final class GoalRevisionRootAdminExecutableProvenanceTests: XCTestCase {
  private typealias Subject =
    TatwoGoalRevisionRootAdminExecutableProvenance

  func testResolveCurrentProcessPathUsesCurrentPIDAndReturnedLength()
    throws
  {
    let expected = "/tmp/tatwo-current-process"

    let actual = try Subject.resolveCurrentProcessPath {
      pid, rawBuffer, capacity in
      XCTAssertEqual(pid, Darwin.getpid())
      let bytes = Array(expected.utf8)
      XCTAssertGreaterThan(Int(capacity), bytes.count)
      let buffer = rawBuffer!.assumingMemoryBound(to: UInt8.self)
      for (offset, byte) in bytes.enumerated() {
        buffer[offset] = byte
      }
      buffer[bytes.count] = 0
      return Int32(bytes.count)
    }

    XCTAssertEqual(actual, expected)
  }

  func testResolveCurrentProcessPathRejectsProviderFailure() {
    assertUntrusted("proc_pidpath") {
      _ = try Subject.resolveCurrentProcessPath {
        _, _, _ in 0
      }
    }
  }

  func testResolveCurrentProcessPathRejectsEmptyAndInvalidUTF8() {
    assertUntrusted("proc_pidpath_encoding") {
      _ = try Subject.resolveCurrentProcessPath {
        _, rawBuffer, _ in
        rawBuffer!.assumingMemoryBound(to: UInt8.self)[0] = 0
        return 1
      }
    }

    assertUntrusted("proc_pidpath_encoding") {
      _ = try Subject.resolveCurrentProcessPath {
        _, rawBuffer, _ in
        let buffer = rawBuffer!.assumingMemoryBound(to: UInt8.self)
        buffer[0] = 0xff
        buffer[1] = 0
        return 1
      }
    }
  }

  func testResolveCurrentProcessPathRejectsUnterminatedCapacity() {
    assertUntrusted("proc_pidpath_termination") {
      _ = try Subject.resolveCurrentProcessPath {
        _, rawBuffer, capacity in
        memset(rawBuffer, 0x61, Int(capacity))
        return Int32(capacity)
      }
    }
  }

  func testResolveCurrentProcessPathRejectsOverReportedLength() {
    assertUntrusted("proc_pidpath") {
      _ = try Subject.resolveCurrentProcessPath {
        _, _, capacity in
        Int32(capacity) + 1
      }
    }
  }

  func testResolveCurrentProcessPathRejectsInteriorNUL() {
    assertUntrusted("proc_pidpath_encoding") {
      _ = try Subject.resolveCurrentProcessPath {
        _, rawBuffer, _ in
        let bytes = Array("/tmp/tatwo\0suffix".utf8)
        let buffer = rawBuffer!.assumingMemoryBound(to: UInt8.self)
        for (offset, byte) in bytes.enumerated() {
          buffer[offset] = byte
        }
        buffer[bytes.count] = 0
        return Int32(bytes.count)
      }
    }
  }

  func testValidateAcceptsExactContentAddressedFixture() throws {
    let fixture = try makeFixture("valid")
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    let evidence = try validate(fixture)

    XCTAssertEqual(evidence.executablePath, fixture.leaf.path)
    XCTAssertEqual(evidence.executableSHA256, sha256Hex(fixture.content))
    XCTAssertEqual(evidence.byteCount, Int64(fixture.content.count))
    XCTAssertFalse(evidence.parentChainDigest.isEmpty)
  }

  func testValidateRejectsMissingAndWrongFixedPath() throws {
    let fixture = try makeFixture("fixed-path")
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    let wrongName = fixture.leaf.deletingLastPathComponent()
      .appendingPathComponent("other-executable")
    assertUntrusted("fixed_path") {
      _ = try Subject.validate(
        executablePath: wrongName.path,
        rootURL: fixture.root,
        directoryComponents: fixture.directoryComponents,
        expectedOwnerUID: Darwin.getuid(),
        expectedGroupID: Darwin.getgid())
    }

    try FileManager.default.removeItem(at: fixture.leaf)
    assertUntrusted("leaf") {
      _ = try validate(fixture)
    }
  }

  func testValidateRejectsNonCanonicalPath() throws {
    let fixture = try makeFixture("canonical-path")
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    assertUntrusted("path") {
      _ = try Subject.validate(
        executablePath: fixture.leaf.path.replacingOccurrences(
          of: "/trusted/",
          with: "/trusted//"),
        rootURL: fixture.root,
        directoryComponents: fixture.directoryComponents,
        expectedOwnerUID: Darwin.getuid(),
        expectedGroupID: Darwin.getgid())
    }
  }

  func testValidateRejectsParentSymlink() throws {
    let fixture = try makeFixture("parent-symlink")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let linkedParent = fixture.root.appendingPathComponent(
      fixture.directoryComponents[0],
      isDirectory: true)
    let actualParent = fixture.root.appendingPathComponent(
      "actual-parent",
      isDirectory: true)
    try FileManager.default.moveItem(
      at: linkedParent,
      to: actualParent)
    try FileManager.default.createSymbolicLink(
      at: linkedParent,
      withDestinationURL: actualParent)

    assertUntrusted("parent_\(fixture.directoryComponents[0])") {
      _ = try validate(fixture)
    }
  }

  func testValidateRejectsLeafSymlink() throws {
    let fixture = try makeFixture("leaf-symlink")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let actualLeaf = fixture.leaf.deletingLastPathComponent()
      .appendingPathComponent("actual-executable")
    try FileManager.default.moveItem(
      at: fixture.leaf,
      to: actualLeaf)
    try FileManager.default.createSymbolicLink(
      at: fixture.leaf,
      withDestinationURL: actualLeaf)

    assertUntrusted("leaf") {
      _ = try validate(fixture)
    }
  }

  func testValidateRejectsWritableAndWrongOwnerParents() throws {
    let writableFixture = try makeFixture("writable-parent")
    defer {
      try? FileManager.default.removeItem(at: writableFixture.root)
    }
    let writableParent = writableFixture.root.appendingPathComponent(
      writableFixture.directoryComponents[0],
      isDirectory: true)
    try chmod(writableParent, 0o775)
    assertUntrusted(
      "directory_\(writableFixture.directoryComponents[0])"
    ) {
      _ = try validate(writableFixture)
    }

    let ownerFixture = try makeFixture("wrong-owner-parent")
    defer { try? FileManager.default.removeItem(at: ownerFixture.root) }
    assertUntrusted("directory_root") {
      _ = try Subject.validate(
        executablePath: ownerFixture.leaf.path,
        rootURL: ownerFixture.root,
        directoryComponents: ownerFixture.directoryComponents,
        expectedOwnerUID: Darwin.getuid() &+ 1,
        expectedGroupID: Darwin.getgid())
    }
  }

  func testDirectoryMetadataAcceptsNonWritableRootOwnedParentWithDifferentGroup()
    throws
  {
    let fixture = try makeFixture("parent-group")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    var status = try status(of: fixture.root)
    status.st_gid = status.st_gid &+ 1

    XCTAssertTrue(
      Subject.directoryMetadataIsTrusted(
        status,
        expectedOwnerUID: Darwin.getuid()))

    status.st_mode |= 0o020
    XCTAssertFalse(
      Subject.directoryMetadataIsTrusted(
        status,
        expectedOwnerUID: Darwin.getuid()))
  }

  func testValidateAcceptsNonWritableParentWithDifferentGroup() throws {
    let fixture = try makeFixture("parent-group-end-to-end")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let parent = fixture.root.appendingPathComponent(
      fixture.directoryComponents[0],
      isDirectory: true)
    let alternateGroup = try alternateGroupID()
    try changeGroup(of: parent, to: alternateGroup)
    let parentStatus = try status(of: parent)
    XCTAssertEqual(parentStatus.st_uid, Darwin.getuid())
    XCTAssertEqual(parentStatus.st_gid, alternateGroup)
    XCTAssertNotEqual(parentStatus.st_gid, Darwin.getgid())
    XCTAssertEqual(parentStatus.st_mode & 0o022, 0)

    let evidence = try validate(fixture)

    XCTAssertEqual(evidence.executablePath, fixture.leaf.path)
    XCTAssertEqual(evidence.executableSHA256, sha256Hex(fixture.content))
  }

  func testValidateRejectsParentExtendedACL() throws {
    let fixture = try makeFixture("parent-acl")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let parent = fixture.root.appendingPathComponent(
      fixture.directoryComponents[0],
      isDirectory: true)
    try addDenyWriteACL(to: parent)

    assertUntrusted("acl_\(fixture.directoryComponents[0])") {
      _ = try validate(fixture)
    }
  }

  func testValidateRejectsLeafExtendedACL() throws {
    let fixture = try makeFixture("leaf-acl")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try addDenyWriteACL(to: fixture.leaf)

    assertUntrusted("acl_leaf") {
      _ = try validate(fixture)
    }
  }

  func testValidateAcceptsAppleProvenanceExtendedAttribute() throws {
    let fixture = try makeFixture("apple-provenance-xattr")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try setExtendedAttribute(
      Subject.allowedExecutableExtendedAttributes.first!,
      on: fixture.leaf)

    let evidence = try validate(fixture)

    XCTAssertEqual(evidence.executablePath, fixture.leaf.path)
    XCTAssertEqual(evidence.executableSHA256, sha256Hex(fixture.content))
  }

  func testValidateRejectsLeafExtendedAttribute() throws {
    let fixture = try makeFixture("leaf-xattr")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try setExtendedAttribute("com.tatwo.test", on: fixture.leaf)

    assertUntrusted("xattr_leaf") {
      _ = try validate(fixture)
    }
  }

  func testValidateRejectsWrongLeafModeAndMetadataRejectsWrongOwner()
    throws
  {
    let modeFixture = try makeFixture("wrong-leaf-mode")
    defer { try? FileManager.default.removeItem(at: modeFixture.root) }
    try chmod(modeFixture.leaf, 0o755)
    assertUntrusted("metadata") {
      _ = try validate(modeFixture)
    }

    let ownerFixture = try makeFixture("wrong-leaf-owner")
    defer { try? FileManager.default.removeItem(at: ownerFixture.root) }
    var leafStatus = try status(of: ownerFixture.leaf)
    let pathStatus = leafStatus
    XCTAssertTrue(
      Subject.executableMetadataIsTrusted(
        leafStatus,
        pathStatus: pathStatus,
        expectedOwnerUID: Darwin.getuid(),
        expectedGroupID: Darwin.getgid()))
    leafStatus.st_uid = Darwin.getuid() &+ 1
    XCTAssertFalse(
      Subject.executableMetadataIsTrusted(
        leafStatus,
        pathStatus: pathStatus,
        expectedOwnerUID: Darwin.getuid(),
        expectedGroupID: Darwin.getgid()))
  }

  func testValidateRejectsHardLinkedLeaf() throws {
    let fixture = try makeFixture("hardlink")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try FileManager.default.linkItem(
      at: fixture.leaf,
      to: fixture.leaf.deletingLastPathComponent()
        .appendingPathComponent("second-link"))

    assertUntrusted("metadata") {
      _ = try validate(fixture)
    }
  }

  func testValidateRejectsMalformedDigestDirectoryAndHashMismatch()
    throws
  {
    let malformed = try makeFixture("malformed-digest")
    defer { try? FileManager.default.removeItem(at: malformed.root) }
    let malformedDirectory = malformed.digestDirectory
      .deletingLastPathComponent()
      .appendingPathComponent("sha256-not-a-digest", isDirectory: true)
    try FileManager.default.moveItem(
      at: malformed.digestDirectory,
      to: malformedDirectory)
    assertUntrusted("digest_directory") {
      _ = try validate(
        malformed,
        executablePath: malformedDirectory.appendingPathComponent(
          Subject.executableFileName).path)
    }

    let mismatch = try makeFixture("hash-mismatch")
    defer { try? FileManager.default.removeItem(at: mismatch.root) }
    let wrongDigestDirectory = mismatch.digestDirectory
      .deletingLastPathComponent()
      .appendingPathComponent(
        "\(Subject.digestDirectoryPrefix)\(String(repeating: "0", count: 64))",
        isDirectory: true)
    try FileManager.default.moveItem(
      at: mismatch.digestDirectory,
      to: wrongDigestDirectory)
    assertUntrusted("digest_or_drift") {
      _ = try validate(
        mismatch,
        executablePath: wrongDigestDirectory.appendingPathComponent(
          Subject.executableFileName).path)
    }
  }

  func testValidateRejectsLeafReplacementAndInodeDrift() throws {
    let fixture = try makeFixture("replacement-drift")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let displaced = fixture.leaf.deletingLastPathComponent()
      .appendingPathComponent("displaced-executable")

    assertUntrusted("digest_or_drift") {
      _ = try validate(
        fixture,
        afterDigestReadForTesting: {
          try FileManager.default.moveItem(
            at: fixture.leaf,
            to: displaced)
          try fixture.content.write(to: fixture.leaf)
          try self.chmod(fixture.leaf, 0o555)
        })
    }
  }

  func testValidateRejectsSizeDriftThroughPreopenedWriter() throws {
    let fixture = try makeFixture("size-drift")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let writer = try openWritableDescriptor(fixture.leaf)
    defer { _ = Darwin.close(writer) }
    var extra: UInt8 = 0x21

    assertUntrusted("digest_or_drift") {
      _ = try validate(
        fixture,
        afterDigestReadForTesting: {
          XCTAssertEqual(Darwin.lseek(writer, 0, SEEK_END), off_t(
            fixture.content.count))
          XCTAssertEqual(Darwin.write(writer, &extra, 1), 1)
        })
    }
  }

  func testValidateRejectsSameSizeDigestDriftThroughPreopenedWriter()
    throws
  {
    let fixture = try makeFixture("digest-drift")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let writer = try openWritableDescriptor(fixture.leaf)
    defer { _ = Darwin.close(writer) }
    var replacement: UInt8 =
      fixture.content.first == 0x7a ? 0x79 : 0x7a

    assertUntrusted("digest_or_drift") {
      _ = try validate(
        fixture,
        afterDigestReadForTesting: {
          usleep(2_000)
          XCTAssertEqual(
            Darwin.pwrite(writer, &replacement, 1, 0),
            1)
        })
    }
  }

  func testMachOLoaderPolicyAcceptsThinArm64SystemClosure() throws {
    XCTAssertNoThrow(try Subject.validateMachOLoaderPolicy(makeMachO()))
  }

  func testMachOLoaderPolicyRejectsFatWrongArchitectureAndHeaderFlags()
    throws
  {
    var fat = makeMachO()
    writeUInt32(0xcafe_babe, to: &fat, at: 0)
    assertUntrusted("macho_thin_arm64") {
      try Subject.validateMachOLoaderPolicy(fat)
    }
    var intel = makeMachO()
    writeUInt32(0x0100_0007, to: &intel, at: 4)
    assertUntrusted("macho_thin_arm64") {
      try Subject.validateMachOLoaderPolicy(intel)
    }
    for flags in [
      UInt32(0x0020_0000),
      UInt32(0x0000_0004),
      UInt32(0x0020_0004 | 0x0000_0100),
      UInt32(0x0020_0004 | 0x0002_0000),
    ] {
      var image = makeMachO()
      writeUInt32(flags, to: &image, at: 24)
      assertUntrusted("macho_header") {
        try Subject.validateMachOLoaderPolicy(image)
      }
    }
  }

  func testMachOLoaderPolicyRejectsRPathAndUnknownRequiredCommand()
    throws
  {
    let rpath = makeMachO(
      additionalCommands: [
        makeStringCommand(
          command: 0x8000_001c,
          fixedByteCount: 12,
          value: "/tmp")
      ])
    assertUntrusted("macho_loader_command") {
      try Subject.validateMachOLoaderPolicy(rpath)
    }
    var unknown = Data()
    appendUInt32(0x8000_007f, to: &unknown)
    appendUInt32(8, to: &unknown)
    assertUntrusted("macho_unknown_required_command") {
      try Subject.validateMachOLoaderPolicy(
        makeMachO(additionalCommands: [unknown]))
    }
  }

  func testMachOLoaderPolicyRejectsUnsafeDylibEntryPointAndDylinker()
    throws
  {
    assertUntrusted("macho_dylib_path") {
      try Subject.validateMachOLoaderPolicy(
        makeMachO(dylibPath: "@rpath/libInjected.dylib"))
    }
    assertUntrusted("macho_loader_closure") {
      try Subject.validateMachOLoaderPolicy(
        makeMachO(includeMain: false))
    }
    assertUntrusted("macho_dylinker") {
      try Subject.validateMachOLoaderPolicy(
        makeMachO(dylinkerPath: "/tmp/dyld"))
    }
  }

  func testMachOLoaderPolicyRejectsSignatureSegmentAndBuildVersion()
    throws
  {
    assertUntrusted("macho_loader_closure") {
      try Subject.validateMachOLoaderPolicy(
        makeMachO(includeCodeSignature: false))
    }
    assertUntrusted("macho_segment") {
      try Subject.validateMachOLoaderPolicy(
        makeMachO(linkeditProtection: 0x6))
    }
    assertUntrusted("macho_build_version") {
      try Subject.validateMachOLoaderPolicy(
        makeMachO(buildPlatform: 2))
    }
  }

  func testMachOLoaderPolicyRejectsTinyAndTruncatedStringCommands()
    throws
  {
    assertUntrusted("macho_string") {
      try Subject.validateMachOLoaderPolicy(
        makeMachO(
          additionalCommands: [
            makeBareCommand(command: 0xe, declaredSize: 8)
          ]))
    }
    assertUntrusted("macho_string") {
      try Subject.validateMachOLoaderPolicy(
        makeMachO(
          additionalCommands: [
            makeBareCommand(command: 0xc, declaredSize: 8)
          ]))
    }
    var malformedDylinker = makeBareCommand(
      command: 0xe,
      declaredSize: 16,
      actualSize: 16)
    writeUInt32(24, to: &malformedDylinker, at: 8)
    assertUntrusted("macho_string") {
      try Subject.validateMachOLoaderPolicy(
        makeMachO(additionalCommands: [malformedDylinker]))
    }
    assertUntrusted("macho_load_commands") {
      try Subject.validateMachOLoaderPolicy(
        makeMachO(
          additionalCommands: [
            makeBareCommand(
              command: 0xc,
              declaredSize: 24,
              actualSize: 8)
          ]))
    }
  }

  func testMachOLoaderPolicyRejectsTinyBuildAndVMRangeOverflow()
    throws
  {
    assertUntrusted("macho_build_version") {
      try Subject.validateMachOLoaderPolicy(
        makeMachO(
          additionalCommands: [
            makeBareCommand(command: 0x32, declaredSize: 8)
          ]))
    }
    assertUntrusted("macho_segment") {
      try Subject.validateMachOLoaderPolicy(
        makeMachO(
          segmentVirtualAddress: UInt64.max - 7,
          segmentVirtualSize: 16))
    }
  }

  func testMachOLoaderPolicyRejectsDuplicateClosureCommands()
    throws
  {
    assertUntrusted("macho_loader_closure") {
      try Subject.validateMachOLoaderPolicy(
        makeMachO(additionalCommands: [makeMainCommand()]))
    }
    assertUntrusted("macho_loader_closure") {
      try Subject.validateMachOLoaderPolicy(
        makeMachO(
          additionalCommands: [
            makeStringCommand(
              command: 0xe,
              fixedByteCount: 12,
              value: "/usr/lib/dyld")
          ]))
    }
    assertUntrusted("macho_code_signature") {
      try Subject.validateMachOLoaderPolicy(
        makeMachO(
          additionalCommands: [
            makeCodeSignatureCommand(
              dataOffset: 1,
              dataSize: 1)
          ]))
    }
    assertUntrusted("macho_loader_closure") {
      try Subject.validateMachOLoaderPolicy(
        makeMachO(additionalCommands: [makeBuildVersionCommand()]))
    }
  }

  func testCodeAttestationPolicyAcceptsExactStaticDynamicBinding()
    throws
  {
    let path = "/trusted/tatwo-ultrawork"
    XCTAssertNoThrow(
      try Subject.validateCodeAttestation(
        makeAttestation(path: path),
        expectedExecutablePath: path))
  }

  func testCodeAttestationPolicyRejectsAdhocDebuggedIdentityAndEntitlements()
    throws
  {
    let path = "/trusted/tatwo-ultrawork"
    assertUntrusted("code_signature_flags") {
      try Subject.validateCodeAttestation(
        makeAttestation(
          path: path,
          staticFlags:
            Subject.codeSignatureFlagRuntime
              | Subject.codeSignatureFlagAdhoc),
        expectedExecutablePath: path)
    }
    assertUntrusted("code_dynamic_status") {
      try Subject.validateCodeAttestation(
        makeAttestation(
          path: path,
          dynamicStatus: Subject.codeSignatureStatusDebugged),
        expectedExecutablePath: path)
    }
    assertUntrusted("code_identity") {
      try Subject.validateCodeAttestation(
        makeAttestation(
          path: path,
          dynamicUnique: Data([0xff])),
        expectedExecutablePath: path)
    }
    for entitlement in [
      "com.apple.security.cs.disable-library-validation",
      "com.apple.security.cs.allow-dyld-environment-variables",
      "com.apple.security.cs.allow-jit",
      "com.apple.security.cs.allow-unsigned-executable-memory",
      "com.apple.security.cs.disable-executable-page-protection",
      "com.apple.security.get-task-allow",
    ] {
      assertUntrusted("code_entitlements") {
        try Subject.validateCodeAttestation(
          makeAttestation(
            path: path,
            staticEntitlements: [entitlement]),
          expectedExecutablePath: path)
      }
    }
  }

  func testDeveloperIDApplicationRequirementParsesWithSecurityFramework()
    throws
  {
    _ = try Subject.makeDeveloperIDApplicationRequirement()
  }

  func testCurrentProcessDynamicSecurityInformationHasTypedFlagsAndStatus()
    throws
  {
    let snapshot =
      try Subject.currentProcessDynamicCodeStatusForTesting()
    let flags: UInt32 = snapshot.flags
    let status: UInt32 = snapshot.status

    XCTAssertNotEqual(flags, 0)
    XCTAssertNotEqual(status & 0x0000_0001, 0)
  }

  func testProductionSecurityAttestationRejectsCurrentAdhocExecutableAtDeveloperIDGate()
    throws
  {
    let currentExecutablePath =
      try Subject.resolveCurrentProcessPath()

    assertUntrusted("static_code_validity") {
      _ = try Subject.securityCodeAttestationForTesting(
        executablePath: currentExecutablePath)
    }
  }

  func testLiveAttestationRunsInsideOpenedDescriptorDriftWindow()
    throws
  {
    let fixture = try makeFixture(
      "live-attestation",
      content: makeMachO())
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    var providerCalled = false
    let evidence = try validateWithLiveAttestation(
      fixture,
      provider: { path in
        providerCalled = true
        return self.makeAttestation(path: path)
      })
    XCTAssertTrue(providerCalled)
    XCTAssertEqual(evidence.executablePath, fixture.leaf.path)

    let writer = try openWritableDescriptor(fixture.leaf)
    defer { _ = Darwin.close(writer) }
    var replacement: UInt8 = 0x42
    assertUntrusted("digest_or_drift") {
      _ = try validateWithLiveAttestation(
        fixture,
        provider: { self.makeAttestation(path: $0) },
        afterLiveAttestationForTesting: {
          usleep(2_000)
          XCTAssertEqual(
            Darwin.pwrite(writer, &replacement, 1, 0),
            1)
        })
    }
  }

  func testLiveAttestationRejectsSameSizeRewriteWithMTimeRestored()
    throws
  {
    let fixture = try makeFixture(
      "live-attestation-restored-mtime",
      content: makeMachO())
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let writer = try openWritableDescriptor(fixture.leaf)
    defer { _ = Darwin.close(writer) }
    let originalStatus = try status(of: fixture.leaf)
    var replacement: UInt8 = 0x42

    assertUntrusted("digest_or_drift") {
      _ = try validateWithLiveAttestation(
        fixture,
        provider: { self.makeAttestation(path: $0) },
        afterLiveAttestationForTesting: {
          XCTAssertEqual(
            Darwin.pwrite(writer, &replacement, 1, 0),
            1)
          let timestamps = [
            originalStatus.st_atimespec,
            originalStatus.st_mtimespec,
          ]
          XCTAssertEqual(
            timestamps.withUnsafeBufferPointer {
              Darwin.futimens(writer, $0.baseAddress)
            },
            0)
          let restoredStatus = try self.status(of: fixture.leaf)
          XCTAssertEqual(
            restoredStatus.st_mtimespec.tv_sec,
            originalStatus.st_mtimespec.tv_sec)
          XCTAssertEqual(
            restoredStatus.st_mtimespec.tv_nsec,
            originalStatus.st_mtimespec.tv_nsec)
        })
    }
  }

  private struct Fixture {
    let root: URL
    let directoryComponents: [String]
    let digestDirectory: URL
    let leaf: URL
    let content: Data
  }

  private func makeFixture(
    _ label: String,
    content: Data = Data("tatwo-provenance-fixture-v1".utf8)
  ) throws -> Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "tatwo-root-admin-provenance-\(label)-\(UUID().uuidString)",
      isDirectory: true)
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: false)
    try chmod(root, 0o755)
    let directoryComponents = ["trusted", "v1"]
    var parent = root
    for component in directoryComponents {
      parent.appendPathComponent(component, isDirectory: true)
      try FileManager.default.createDirectory(
        at: parent,
        withIntermediateDirectories: false)
      try chmod(parent, 0o755)
    }
    let digestDirectory = parent.appendingPathComponent(
      "\(Subject.digestDirectoryPrefix)\(sha256Hex(content))",
      isDirectory: true)
    try FileManager.default.createDirectory(
      at: digestDirectory,
      withIntermediateDirectories: false)
    try chmod(digestDirectory, 0o755)
    let leaf = digestDirectory.appendingPathComponent(
      Subject.executableFileName)
    try content.write(to: leaf)
    try chmod(leaf, 0o555)
    return Fixture(
      root: root,
      directoryComponents: directoryComponents,
      digestDirectory: digestDirectory,
      leaf: leaf,
      content: content)
  }

  private func validate(
    _ fixture: Fixture,
    executablePath: String? = nil,
    afterDigestReadForTesting: (() throws -> Void)? = nil
  ) throws -> TatwoGoalRevisionRootAdminExecutableProvenanceV1 {
    try Subject.validate(
      executablePath: executablePath ?? fixture.leaf.path,
      rootURL: fixture.root,
      directoryComponents: fixture.directoryComponents,
      expectedOwnerUID: Darwin.getuid(),
      expectedGroupID: Darwin.getgid(),
      afterDigestReadForTesting: afterDigestReadForTesting)
  }

  private func validateWithLiveAttestation(
    _ fixture: Fixture,
    provider: @escaping Subject.CodeAttestationProvider,
    afterLiveAttestationForTesting: (() throws -> Void)? = nil
  ) throws -> TatwoGoalRevisionRootAdminExecutableProvenanceV1 {
    try Subject.validateWithLiveAttestationForTesting(
      executablePath: fixture.leaf.path,
      rootURL: fixture.root,
      directoryComponents: fixture.directoryComponents,
      expectedOwnerUID: Darwin.getuid(),
      expectedGroupID: Darwin.getgid(),
      provider: provider,
      afterLiveAttestationForTesting:
        afterLiveAttestationForTesting)
  }

  private func makeAttestation(
    path: String,
    staticFlags: UInt32 = Subject.codeSignatureFlagRuntime,
    dynamicFlags: UInt32 = Subject.codeSignatureFlagRuntime,
    dynamicStatus: UInt32 = 0,
    dynamicUnique: Data = Data([0x01, 0x02, 0x03]),
    staticEntitlements: Set<String> = [],
    dynamicEntitlements: Set<String> = []
  ) -> Subject.CodeAttestationSnapshot {
    let staticIdentity = Subject.CodeIdentitySnapshot(
      identifier: Subject.signingIdentifier,
      teamIdentifier: Subject.signingTeamIdentifier,
      unique: Data([0x01, 0x02, 0x03]),
      canonicalExecutablePath: path,
      flags: staticFlags,
      dynamicStatus: nil,
      entitlementKeys: staticEntitlements)
    let dynamicIdentity = Subject.CodeIdentitySnapshot(
      identifier: Subject.signingIdentifier,
      teamIdentifier: Subject.signingTeamIdentifier,
      unique: dynamicUnique,
      canonicalExecutablePath: path,
      flags: dynamicFlags,
      dynamicStatus: dynamicStatus,
      entitlementKeys: dynamicEntitlements)
    return Subject.CodeAttestationSnapshot(
      staticCode: staticIdentity,
      dynamicCode: dynamicIdentity)
  }

  private func makeMachO(
    dylinkerPath: String = "/usr/lib/dyld",
    dylibPath: String = "/usr/lib/libSystem.B.dylib",
    includeMain: Bool = true,
    includeCodeSignature: Bool = true,
    linkeditProtection: UInt32 = 0x1,
    buildPlatform: UInt32 = 1,
    segmentVirtualAddress: UInt64 = 0,
    segmentVirtualSize: UInt64? = nil,
    additionalCommands: [Data] = []
  ) -> Data {
    func commands(signatureOffset: UInt32) -> [Data] {
      var result = [
        makeSegmentCommand(
          fileOffset: UInt64(signatureOffset),
          fileSize: includeCodeSignature ? 16 : 0,
          protection: linkeditProtection,
          virtualAddress: segmentVirtualAddress,
          virtualSize:
            segmentVirtualSize
              ?? (includeCodeSignature ? 16 : 0)),
        makeStringCommand(
          command: 0xe,
          fixedByteCount: 12,
          value: dylinkerPath),
        makeStringCommand(
          command: 0xc,
          fixedByteCount: 24,
          value: dylibPath),
      ]
      if includeMain {
        result.append(makeMainCommand())
      }
      if includeCodeSignature {
        result.append(
          makeCodeSignatureCommand(
            dataOffset: signatureOffset,
            dataSize: 16))
      }
      result.append(
        makeBuildVersionCommand(platform: buildPlatform))
      result.append(contentsOf: additionalCommands)
      return result
    }

    let preliminary = commands(signatureOffset: 0)
    let commandsByteCount = preliminary.reduce(0) {
      $0 + $1.count
    }
    let signatureOffset = UInt32(32 + commandsByteCount)
    let loadCommands = commands(signatureOffset: signatureOffset)
    var image = Data()
    appendUInt32(0xfeed_facf, to: &image)
    appendUInt32(0x0100_000c, to: &image)
    appendUInt32(0, to: &image)
    appendUInt32(2, to: &image)
    appendUInt32(UInt32(loadCommands.count), to: &image)
    appendUInt32(UInt32(commandsByteCount), to: &image)
    appendUInt32(0x0020_0004, to: &image)
    appendUInt32(0, to: &image)
    for command in loadCommands {
      image.append(command)
    }
    if includeCodeSignature {
      image.append(Data(repeating: 0xa5, count: 16))
    }
    return image
  }

  private func makeSegmentCommand(
    fileOffset: UInt64,
    fileSize: UInt64,
    protection: UInt32,
    virtualAddress: UInt64,
    virtualSize: UInt64
  ) -> Data {
    var command = Data()
    appendUInt32(0x19, to: &command)
    appendUInt32(72, to: &command)
    appendFixedString("__LINKEDIT", byteCount: 16, to: &command)
    appendUInt64(virtualAddress, to: &command)
    appendUInt64(virtualSize, to: &command)
    appendUInt64(fileOffset, to: &command)
    appendUInt64(fileSize, to: &command)
    appendUInt32(protection, to: &command)
    appendUInt32(protection, to: &command)
    appendUInt32(0, to: &command)
    appendUInt32(0, to: &command)
    return command
  }

  private func makeMainCommand() -> Data {
    var command = Data()
    appendUInt32(0x8000_0028, to: &command)
    appendUInt32(24, to: &command)
    appendUInt64(0, to: &command)
    appendUInt64(0, to: &command)
    return command
  }

  private func makeCodeSignatureCommand(
    dataOffset: UInt32,
    dataSize: UInt32
  ) -> Data {
    var command = Data()
    appendUInt32(0x1d, to: &command)
    appendUInt32(16, to: &command)
    appendUInt32(dataOffset, to: &command)
    appendUInt32(dataSize, to: &command)
    return command
  }

  private func makeBuildVersionCommand(
    platform: UInt32 = 1
  ) -> Data {
    var command = Data()
    appendUInt32(0x32, to: &command)
    appendUInt32(24, to: &command)
    appendUInt32(platform, to: &command)
    appendUInt32(0x000d_0000, to: &command)
    appendUInt32(0x000d_0000, to: &command)
    appendUInt32(0, to: &command)
    return command
  }

  private func makeBareCommand(
    command: UInt32,
    declaredSize: UInt32,
    actualSize: Int? = nil
  ) -> Data {
    let byteCount = actualSize ?? Int(declaredSize)
    precondition(byteCount >= 8)
    var data = Data()
    appendUInt32(command, to: &data)
    appendUInt32(declaredSize, to: &data)
    data.append(Data(repeating: 0, count: byteCount - 8))
    return data
  }

  private func makeStringCommand(
    command: UInt32,
    fixedByteCount: Int,
    value: String
  ) -> Data {
    let unalignedSize = fixedByteCount + value.utf8.count + 1
    let commandSize = (unalignedSize + 7) & ~7
    var result = Data()
    appendUInt32(command, to: &result)
    appendUInt32(UInt32(commandSize), to: &result)
    appendUInt32(UInt32(fixedByteCount), to: &result)
    if fixedByteCount > 12 {
      result.append(Data(repeating: 0, count: fixedByteCount - 12))
    }
    result.append(contentsOf: value.utf8)
    result.append(0)
    result.append(
      Data(repeating: 0, count: commandSize - result.count))
    return result
  }

  private func appendFixedString(
    _ value: String,
    byteCount: Int,
    to data: inout Data
  ) {
    let bytes = Array(value.utf8.prefix(byteCount))
    data.append(contentsOf: bytes)
    data.append(
      Data(repeating: 0, count: byteCount - bytes.count))
  }

  private func appendUInt32(_ value: UInt32, to data: inout Data) {
    data.append(UInt8(truncatingIfNeeded: value))
    data.append(UInt8(truncatingIfNeeded: value >> 8))
    data.append(UInt8(truncatingIfNeeded: value >> 16))
    data.append(UInt8(truncatingIfNeeded: value >> 24))
  }

  private func appendUInt64(_ value: UInt64, to data: inout Data) {
    appendUInt32(UInt32(truncatingIfNeeded: value), to: &data)
    appendUInt32(UInt32(truncatingIfNeeded: value >> 32), to: &data)
  }

  private func writeUInt32(
    _ value: UInt32,
    to data: inout Data,
    at offset: Int
  ) {
    data[offset] = UInt8(truncatingIfNeeded: value)
    data[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    data[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
    data[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
  }

  private func assertUntrusted(
    _ field: String,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ operation: () throws -> Void
  ) {
    XCTAssertThrowsError(
      try operation(),
      file: file,
      line: line
    ) { error in
      XCTAssertEqual(
        error as? TatwoGoalRevisionRootAdminEnrollmentError,
        .untrustedExecutable(field),
        file: file,
        line: line)
    }
  }

  private func chmod(_ url: URL, _ mode: mode_t) throws {
    guard Darwin.chmod(url.path, mode) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
  }

  private func status(of url: URL) throws -> stat {
    var result = stat()
    guard Darwin.lstat(url.path, &result) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    return result
  }

  private func openWritableDescriptor(_ url: URL) throws -> Int32 {
    try chmod(url, 0o755)
    let descriptor = Darwin.open(
      url.path,
      O_WRONLY | O_CLOEXEC)
    let savedErrno = errno
    try chmod(url, 0o555)
    guard descriptor >= 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: savedErrno) ?? .EIO)
    }
    return descriptor
  }

  private func addDenyWriteACL(to url: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/chmod")
    process.arguments = ["+a", "everyone deny write", url.path]
    let errorPipe = Pipe()
    process.standardOutput = FileHandle.nullDevice
    process.standardError = errorPipe
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      let message = String(
        decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(),
        as: UTF8.self)
      throw NSError(
        domain: "GoalRevisionRootAdminExecutableProvenanceTests",
        code: Int(process.terminationStatus),
        userInfo: [NSLocalizedDescriptionKey: message])
    }
  }

  private func alternateGroupID() throws -> gid_t {
    let primaryGroup = Darwin.getgid()
    let capacity = Darwin.getgroups(0, nil)
    guard capacity > 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    var groups = [gid_t](repeating: 0, count: Int(capacity))
    let count = groups.withUnsafeMutableBufferPointer { buffer in
      Darwin.getgroups(capacity, buffer.baseAddress)
    }
    guard count > 0,
      let alternate = groups.prefix(Int(count)).first(where: {
        $0 != primaryGroup
      })
    else {
      throw NSError(
        domain: "GoalRevisionRootAdminExecutableProvenanceTests",
        code: 1,
        userInfo: [
          NSLocalizedDescriptionKey:
            "A supplemental group is required; this regression must not skip"
        ])
    }
    return alternate
  }

  private func changeGroup(of url: URL, to group: gid_t) throws {
    guard Darwin.chown(url.path, uid_t.max, group) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
  }

  private func setExtendedAttribute(_ attribute: String, on url: URL) throws {
    try chmod(url, 0o755)
    defer { try? chmod(url, 0o555) }
    var value: UInt8 = 1
    let result = url.path.withCString { path in
      attribute.withCString { name in
        withUnsafePointer(to: &value) { pointer in
          Darwin.setxattr(
            path,
            name,
            pointer,
            MemoryLayout<UInt8>.size,
            0,
            0)
        }
      }
    }
    guard result == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
  }

  private func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data)
      .map { String(format: "%02x", $0) }
      .joined()
  }
}
#endif
