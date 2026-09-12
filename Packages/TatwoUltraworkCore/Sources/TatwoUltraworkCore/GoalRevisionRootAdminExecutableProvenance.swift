import CryptoKit
import Foundation
#if canImport(Darwin)
import Darwin
#if os(macOS)
import Security
#endif
#endif

/// Evidence that the root-admin enrollment command is executing from the
/// exact root-owned, content-addressed binary selected by a separate admin
/// installation gate.
///
/// This value is audit evidence only. It is not a reusable issuer, key, or
/// authorization, and it does not install or repair the executable.
struct TatwoGoalRevisionRootAdminExecutableProvenanceV1:
  Sendable, Equatable
{
  let executablePath: String
  let executableSHA256: String
  let parentChainDigest: String
  let device: UInt64
  let inode: UInt64
  let byteCount: Int64
}

enum TatwoGoalRevisionRootAdminExecutableProvenance {
  typealias CurrentProcessPathProvider = (
    _ pid: pid_t,
    _ buffer: UnsafeMutableRawPointer?,
    _ capacity: UInt32
  ) -> Int32

  static let productionDirectoryComponents = [
    "Library",
    "Application Support",
    "Tatwo Ultrawork",
    "GoalRecoveryEnrollmentExecutables",
    "v1",
  ]
  static let executableFileName = "tatwo-ultrawork"
  static let digestDirectoryPrefix = "sha256-"
  static let maximumExecutableByteCount: off_t = 512 * 1024 * 1024
  static let allowedExecutableExtendedAttributes: Set<String> = [
    "com.apple.provenance"
  ]
  static let maximumExtendedAttributeListByteCount = 64 * 1024
  static let signingIdentifier =
    "com.tatwo.ultrawork.goal-recovery-bootstrap"
  static let signingTeamIdentifier = "W47594XKQC"
  static let developerIDApplicationRequirement =
    """
    anchor apple generic and identifier \
    "\(signingIdentifier)" and certificate leaf\
    [field.1.2.840.113635.100.6.1.13] exists and certificate 1\
    [field.1.2.840.113635.100.6.2.6] exists and certificate leaf\
    [subject.OU] = "\(signingTeamIdentifier)"
    """
  static let codeSignatureFlagAdhoc: UInt32 = 0x0000_0002
  static let codeSignatureFlagGetTaskAllow: UInt32 = 0x0000_0004
  static let codeSignatureFlagRuntime: UInt32 = 0x0001_0000
  static let codeSignatureStatusDebugged: UInt32 = 0x1000_0000

  struct CodeIdentitySnapshot: Sendable, Equatable {
    let identifier: String
    let teamIdentifier: String
    let unique: Data
    let canonicalExecutablePath: String
    let flags: UInt32
    let dynamicStatus: UInt32?
    let entitlementKeys: Set<String>
  }

  struct CodeAttestationSnapshot: Sendable, Equatable {
    let staticCode: CodeIdentitySnapshot
    let dynamicCode: CodeIdentitySnapshot
  }

  struct DynamicCodeStatusSnapshot: Sendable, Equatable {
    let flags: UInt32
    let status: UInt32
  }

  typealias CodeAttestationProvider = (
    _ executablePath: String
  ) throws -> CodeAttestationSnapshot

  #if os(macOS)
  static func validateCurrentProcess()
    throws -> TatwoGoalRevisionRootAdminExecutableProvenanceV1
  {
    let path = try resolveCurrentProcessPath()
    return try validateOpenedExecutable(
      executablePath: path,
      rootURL: URL(fileURLWithPath: "/", isDirectory: true),
      directoryComponents: productionDirectoryComponents,
      expectedOwnerUID: 0,
      expectedGroupID: 0,
      liveAttestation: { descriptor, byteCount in
        try validateMachOLoaderPolicy(
          descriptor: descriptor,
          byteCount: byteCount)
        try validateCodeAttestation(
          securityCodeAttestation(executablePath: path),
          expectedExecutablePath: path)
      })
  }

  static func resolveCurrentProcessPath() throws -> String {
    try resolveCurrentProcessPath { pid, buffer, capacity in
      proc_pidpath(pid, buffer, capacity)
    }
  }

  static func resolveCurrentProcessPath(
    using provider: CurrentProcessPathProvider
  ) throws -> String {
    let pathCapacity = Int(MAXPATHLEN) * 4
    guard pathCapacity > 0,
      let procPIDPathCapacity = UInt32(exactly: pathCapacity)
    else {
      throw TatwoGoalRevisionRootAdminEnrollmentError
        .untrustedExecutable("proc_pidpath_capacity")
    }
    var buffer = [CChar](
      repeating: 0,
      count: pathCapacity)
    let byteCount = buffer.withUnsafeMutableBytes { bytes in
      provider(
        Darwin.getpid(),
        bytes.baseAddress,
        procPIDPathCapacity)
    }
    guard byteCount > 0 else {
      throw TatwoGoalRevisionRootAdminEnrollmentError
        .untrustedExecutable("proc_pidpath")
    }
    let copiedCount = Int(byteCount)
    guard copiedCount <= pathCapacity else {
      throw TatwoGoalRevisionRootAdminEnrollmentError
        .untrustedExecutable("proc_pidpath")
    }
    let copiedBytes = buffer.prefix(copiedCount).map {
      UInt8(bitPattern: $0)
    }
    let pathBytes: ArraySlice<UInt8>
    if copiedBytes.last == 0 {
      pathBytes = copiedBytes.dropLast()
    } else {
      guard copiedCount < buffer.count,
        buffer[copiedCount] == 0
      else {
        throw TatwoGoalRevisionRootAdminEnrollmentError
          .untrustedExecutable("proc_pidpath_termination")
      }
      pathBytes = copiedBytes[...]
    }
    guard !pathBytes.isEmpty,
      !pathBytes.contains(0),
      let path = String(bytes: pathBytes, encoding: .utf8),
      !path.isEmpty
    else {
      throw TatwoGoalRevisionRootAdminEnrollmentError
        .untrustedExecutable("proc_pidpath_encoding")
    }
    return path
  }

  static func validate(
    executablePath: String,
    rootURL: URL,
    directoryComponents: [String],
    expectedOwnerUID: uid_t,
    expectedGroupID: gid_t,
    afterDigestReadForTesting: (() throws -> Void)? = nil
  ) throws -> TatwoGoalRevisionRootAdminExecutableProvenanceV1 {
    try validateOpenedExecutable(
      executablePath: executablePath,
      rootURL: rootURL,
      directoryComponents: directoryComponents,
      expectedOwnerUID: expectedOwnerUID,
      expectedGroupID: expectedGroupID,
      afterDigestReadForTesting: afterDigestReadForTesting,
      liveAttestation: nil)
  }

  static func validateWithLiveAttestationForTesting(
    executablePath: String,
    rootURL: URL,
    directoryComponents: [String],
    expectedOwnerUID: uid_t,
    expectedGroupID: gid_t,
    provider: @escaping CodeAttestationProvider,
    afterLiveAttestationForTesting: (() throws -> Void)? = nil
  ) throws -> TatwoGoalRevisionRootAdminExecutableProvenanceV1 {
    try validateOpenedExecutable(
      executablePath: executablePath,
      rootURL: rootURL,
      directoryComponents: directoryComponents,
      expectedOwnerUID: expectedOwnerUID,
      expectedGroupID: expectedGroupID,
      liveAttestation: { descriptor, byteCount in
        try validateMachOLoaderPolicy(
          descriptor: descriptor,
          byteCount: byteCount)
        try validateCodeAttestation(
          provider(executablePath),
          expectedExecutablePath: executablePath)
        try afterLiveAttestationForTesting?()
      })
  }

  private static func validateOpenedExecutable(
    executablePath: String,
    rootURL: URL,
    directoryComponents: [String],
    expectedOwnerUID: uid_t,
    expectedGroupID: gid_t,
    afterDigestReadForTesting: (() throws -> Void)? = nil,
    liveAttestation: ((_ descriptor: Int32, _ byteCount: off_t) throws -> Void)?
  ) throws -> TatwoGoalRevisionRootAdminExecutableProvenanceV1 {
    guard isCanonicalAbsolutePath(executablePath),
      !directoryComponents.isEmpty,
      directoryComponents.allSatisfy(isSafeComponent)
    else {
      throw TatwoGoalRevisionRootAdminEnrollmentError
        .untrustedExecutable("path")
    }
    let pathComponents = executablePath.split(
      separator: "/", omittingEmptySubsequences: true
    ).map(String.init)
    let rootComponents = rootURL.path.split(
      separator: "/", omittingEmptySubsequences: true
    ).map(String.init)
    let expectedPrefix = rootComponents + directoryComponents
    guard pathComponents.count == expectedPrefix.count + 2,
      Array(pathComponents.prefix(expectedPrefix.count)) == expectedPrefix,
      pathComponents.last == executableFileName
    else {
      throw TatwoGoalRevisionRootAdminEnrollmentError
        .untrustedExecutable("fixed_path")
    }
    let digestComponent = pathComponents[pathComponents.count - 2]
    guard digestComponent.hasPrefix(digestDirectoryPrefix) else {
      throw TatwoGoalRevisionRootAdminEnrollmentError
        .untrustedExecutable("digest_directory")
    }
    let expectedDigest = String(
      digestComponent.dropFirst(digestDirectoryPrefix.count))
    guard isLowercaseSHA256(expectedDigest) else {
      throw TatwoGoalRevisionRootAdminEnrollmentError
        .untrustedExecutable("digest_directory")
    }

    let rootFD = rootURL.path.withCString {
      Darwin.open(
        $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    }
    guard rootFD >= 0 else {
      throw TatwoGoalRevisionRootAdminEnrollmentError
        .untrustedExecutable("root_open")
    }
    defer { _ = Darwin.close(rootFD) }
    let rootStatus = try validateDirectory(
      descriptor: rootFD,
      expectedOwnerUID: expectedOwnerUID,
      field: "root")
    try validateNoExtendedACL(
      descriptor: rootFD,
      field: "root")

    var currentFD = Darwin.dup(rootFD)
    guard currentFD >= 0 else {
      throw TatwoGoalRevisionRootAdminEnrollmentError
        .untrustedExecutable("root_dup")
    }
    defer { _ = Darwin.close(currentFD) }
    var parentEvidence: [String] = []
    parentEvidence.reserveCapacity(directoryComponents.count + 2)
    parentEvidence.append(
      directoryEvidence(component: "/", status: rootStatus))

    for component in directoryComponents + [digestComponent] {
      let nextFD = component.withCString {
        Darwin.openat(
          currentFD,
          $0,
          O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      }
      guard nextFD >= 0 else {
        throw TatwoGoalRevisionRootAdminEnrollmentError
          .untrustedExecutable("parent_\(component)")
      }
      do {
        let status = try validateDirectory(
          descriptor: nextFD,
          expectedOwnerUID: expectedOwnerUID,
          field: component)
        try validateNoExtendedACL(
          descriptor: nextFD,
          field: component)
        parentEvidence.append(
          directoryEvidence(component: component, status: status))
      } catch {
        _ = Darwin.close(nextFD)
        throw error
      }
      _ = Darwin.close(currentFD)
      currentFD = nextFD
    }

    var pathBefore = stat()
    guard executableFileName.withCString({
      Darwin.fstatat(
        currentFD,
        $0,
        &pathBefore,
        AT_SYMLINK_NOFOLLOW)
    }) == 0,
      (pathBefore.st_mode & S_IFMT) == S_IFREG
    else {
      throw TatwoGoalRevisionRootAdminEnrollmentError
        .untrustedExecutable("leaf")
    }
    let executableFD = executableFileName.withCString {
      Darwin.openat(
        currentFD,
        $0,
        O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    }
    guard executableFD >= 0 else {
      throw TatwoGoalRevisionRootAdminEnrollmentError
        .untrustedExecutable("open")
    }
    defer { _ = Darwin.close(executableFD) }
    var before = stat()
    guard Darwin.fstat(executableFD, &before) == 0,
      executableMetadataIsTrusted(
        before,
        pathStatus: pathBefore,
        expectedOwnerUID: expectedOwnerUID,
        expectedGroupID: expectedGroupID)
    else {
      throw TatwoGoalRevisionRootAdminEnrollmentError
        .untrustedExecutable("metadata")
    }
    try validateNoExtendedACL(
      descriptor: executableFD,
      field: "leaf")
    try validateNoExtendedAttributes(
      descriptor: executableFD,
      field: "leaf")

    let digestBeforeAttestation = try sha256(
      descriptor: executableFD,
      expectedSize: before.st_size)
    try afterDigestReadForTesting?()
    let filesystemIdentityBefore =
      try liveAttestation.map {
        _ in try localAPFSIdentity(descriptor: executableFD)
      }
    try liveAttestation?(executableFD, before.st_size)
    if let filesystemIdentityBefore {
      guard filesystemIdentityBefore
        == (try localAPFSIdentity(descriptor: executableFD))
      else {
        throw TatwoGoalRevisionRootAdminEnrollmentError
          .untrustedExecutable("filesystem_drift")
      }
    }
    let digestAfterAttestation: String
    do {
      digestAfterAttestation = try sha256(
        descriptor: executableFD,
        expectedSize: before.st_size)
    } catch {
      throw untrusted("digest_or_drift")
    }
    var after = stat()
    var pathAfter = stat()
    guard digestBeforeAttestation == expectedDigest,
      digestAfterAttestation == expectedDigest,
      digestBeforeAttestation == digestAfterAttestation,
      Darwin.fstat(executableFD, &after) == 0,
      sameRevision(before, after),
      executableFileName.withCString({
        Darwin.fstatat(
          currentFD,
          $0,
          &pathAfter,
          AT_SYMLINK_NOFOLLOW)
      }) == 0,
      sameRevision(pathBefore, pathAfter)
    else {
      throw TatwoGoalRevisionRootAdminEnrollmentError
        .untrustedExecutable("digest_or_drift")
    }
    try validateNoExtendedACL(
      descriptor: executableFD,
      field: "leaf")
    try validateNoExtendedAttributes(
      descriptor: executableFD,
      field: "leaf")

    return TatwoGoalRevisionRootAdminExecutableProvenanceV1(
      executablePath: executablePath,
      executableSHA256: digestAfterAttestation,
      parentChainDigest:
        TatwoGoalRevisionBootstrapRecoveryEvidenceV1.digest(
          Data(parentEvidence.joined(separator: "\n").utf8)),
      device: UInt64(before.st_dev),
      inode: UInt64(before.st_ino),
      byteCount: Int64(before.st_size))
  }

  static func validateMachOLoaderPolicy(_ data: Data) throws {
    try validateMachOLoaderPolicy(
      data,
      fileByteCount: UInt64(data.count))
  }

  static func validateMachOLoaderPolicy(
    _ data: Data,
    fileByteCount: UInt64
  ) throws {
    let headerByteCount = 32
    guard data.count >= headerByteCount,
      readUInt32(data, at: 0) == 0xfeed_facf
    else {
      throw untrusted("macho_thin_arm64")
    }
    guard readUInt32(data, at: 4) == 0x0100_000c,
      readUInt32(data, at: 8) == 0,
      readUInt32(data, at: 12) == 2
    else {
      throw untrusted("macho_thin_arm64")
    }
    let commandCount = try exactInt(readUInt32(data, at: 16))
    let commandsByteCount = try exactInt(readUInt32(data, at: 20))
    let flags = readUInt32(data, at: 24)
    guard commandCount > 0,
      let minimumCommandsByteCount =
        checkedMultiply(commandCount, 8),
      commandsByteCount >= minimumCommandsByteCount,
      let commandsEnd = checkedAdd(headerByteCount, commandsByteCount),
      commandsEnd <= data.count,
      UInt64(commandsEnd) <= fileByteCount,
      flags & 0x0000_0004 != 0,
      flags & 0x0020_0000 != 0,
      flags & 0x0000_0100 == 0,
      flags & 0x0002_0000 == 0
    else {
      throw untrusted("macho_header")
    }

    let allowedCommands: Set<UInt32> = [
      0x19, 0x2, 0xb, 0xc, 0xe, 0x1b, 0x8000_0018,
      0x1d, 0x1e, 0x22, 0x8000_0022, 0x26, 0x29,
      0x2a, 0x2b, 0x2e, 0x31, 0x32, 0x8000_0028, 0x8000_0033,
      0x8000_0034,
    ]
    let forbiddenCommands: Set<UInt32> = [
      0x8000_001c, 0x27, 0x1f, 0x8000_0023, 0x20,
      0xd, 0x10, 0x3, 0x6, 0x4, 0x5,
    ]
    var offset = headerByteCount
    var mainCount = 0
    var dylinkerCount = 0
    var codeSignatureRange: Range<UInt64>?
    var buildVersionCount = 0
    var segmentRanges: [Range<UInt64>] = []

    for _ in 0..<commandCount {
      guard offset % 8 == 0,
        let minimumEnd = checkedAdd(offset, 8),
        minimumEnd <= commandsEnd
      else {
        throw untrusted("macho_load_commands")
      }
      let command = readUInt32(data, at: offset)
      let commandSize = try exactInt(readUInt32(data, at: offset + 4))
      guard commandSize >= 8,
        commandSize % 8 == 0,
        let commandEnd = checkedAdd(offset, commandSize),
        commandEnd <= commandsEnd
      else {
        throw untrusted("macho_load_commands")
      }
      guard !forbiddenCommands.contains(command) else {
        throw untrusted("macho_loader_command")
      }
      guard allowedCommands.contains(command) else {
        throw untrusted(
          command & 0x8000_0000 == 0
            ? "macho_load_command_allowlist"
            : "macho_unknown_required_command")
      }

      switch command {
      case 0x8000_0028:
        guard commandSize == 24 else {
          throw untrusted("macho_main")
        }
        mainCount += 1
      case 0xe:
        guard try loadCommandString(
          data,
          commandOffset: offset,
          commandSize: commandSize,
          stringOffsetField: 8,
          minimumStringOffset: 12) == "/usr/lib/dyld"
        else {
          throw untrusted("macho_dylinker")
        }
        dylinkerCount += 1
      case 0xc, 0x8000_0018:
        let path = try loadCommandString(
          data,
          commandOffset: offset,
          commandSize: commandSize,
          stringOffsetField: 8,
          minimumStringOffset: 24)
        guard isCanonicalSystemDylibPath(path) else {
          throw untrusted("macho_dylib_path")
        }
      case 0x1d:
        guard commandSize == 16,
          codeSignatureRange == nil
        else {
          throw untrusted("macho_code_signature")
        }
        let dataOffset = UInt64(readUInt32(data, at: offset + 8))
        let dataSize = UInt64(readUInt32(data, at: offset + 12))
        guard dataSize > 0,
          let dataEnd = checkedAdd(dataOffset, dataSize),
          dataOffset >= UInt64(commandsEnd),
          dataEnd <= fileByteCount
        else {
          throw untrusted("macho_code_signature")
        }
        codeSignatureRange = dataOffset..<dataEnd
      case 0x19:
        guard commandSize >= 72 else {
          throw untrusted("macho_segment")
        }
        let sectionCount = try exactInt(readUInt32(data, at: offset + 64))
        guard let sectionBytes = checkedMultiply(sectionCount, 80),
          checkedAdd(72, sectionBytes) == commandSize
        else {
          throw untrusted("macho_segment")
        }
        let segmentName = try fixedCString(
          data,
          range: (offset + 8)..<(offset + 24))
        let virtualAddress = readUInt64(data, at: offset + 24)
        let virtualSize = readUInt64(data, at: offset + 32)
        let fileOffset = readUInt64(data, at: offset + 40)
        let fileSize = readUInt64(data, at: offset + 48)
        let maximumProtection = readUInt32(data, at: offset + 56)
        let initialProtection = readUInt32(data, at: offset + 60)
        let writeExecuteMask: UInt32 = 0x2 | 0x4
        guard maximumProtection & writeExecuteMask != writeExecuteMask,
          initialProtection & writeExecuteMask != writeExecuteMask,
          segmentName != "__TEXT"
            || (maximumProtection & 0x2 == 0
              && initialProtection & 0x2 == 0),
          segmentName != "__LINKEDIT"
            || (maximumProtection & 0x6 == 0
              && initialProtection & 0x6 == 0),
          let virtualAddressEnd =
            checkedAdd(virtualAddress, virtualSize),
          let fileEnd = checkedAdd(fileOffset, fileSize),
          fileEnd <= fileByteCount
        else {
          throw untrusted("macho_segment")
        }
        for sectionIndex in 0..<sectionCount {
          guard let sectionOffset = checkedAdd(
            offset + 72,
            sectionIndex * 80)
          else {
            throw untrusted("macho_section")
          }
          let sectionSegmentName = try fixedCString(
            data,
            range:
              (sectionOffset + 16)..<(sectionOffset + 32))
          let sectionAddress = readUInt64(
            data,
            at: sectionOffset + 32)
          let sectionSize = readUInt64(
            data,
            at: sectionOffset + 40)
          let sectionFileOffset = UInt64(
            readUInt32(data, at: sectionOffset + 48))
          let alignment = readUInt32(
            data,
            at: sectionOffset + 52)
          let relocationOffset = UInt64(
            readUInt32(data, at: sectionOffset + 56))
          let relocationCount = UInt64(
            readUInt32(data, at: sectionOffset + 60))
          let sectionType =
            readUInt32(data, at: sectionOffset + 64) & 0xff
          guard sectionSegmentName == segmentName,
            alignment < 64,
            let sectionAddressEnd =
              checkedAdd(sectionAddress, sectionSize),
            sectionAddress >= virtualAddress,
            sectionAddressEnd <= virtualAddressEnd,
            let relocationBytes =
              checkedMultiply(relocationCount, 8),
            let relocationEnd =
              checkedAdd(relocationOffset, relocationBytes),
            relocationEnd <= fileByteCount
          else {
            throw untrusted("macho_section")
          }
          let zeroFillTypes: Set<UInt32> = [0x1, 0xc, 0x12]
          if sectionSize > 0,
            !zeroFillTypes.contains(sectionType)
          {
            guard let sectionFileEnd =
              checkedAdd(sectionFileOffset, sectionSize),
              sectionFileOffset >= fileOffset,
              sectionFileEnd <= fileEnd
            else {
              throw untrusted("macho_section")
            }
          }
        }
        if fileSize > 0 {
          let range = fileOffset..<fileEnd
          guard segmentRanges.allSatisfy({ !$0.overlaps(range) }) else {
            throw untrusted("macho_segment_overlap")
          }
          segmentRanges.append(range)
        }
      case 0x32:
        guard commandSize >= 24 else {
          throw untrusted("macho_build_version")
        }
        let minimumOSVersion = readUInt32(
          data,
          at: offset + 12)
        let SDKVersion = readUInt32(
          data,
          at: offset + 16)
        guard readUInt32(data, at: offset + 8) == 1,
          minimumOSVersion > 0,
          SDKVersion >= minimumOSVersion
        else {
          throw untrusted("macho_build_version")
        }
        let toolCount = try exactInt(readUInt32(data, at: offset + 20))
        guard let toolBytes = checkedMultiply(toolCount, 8),
          checkedAdd(24, toolBytes) == commandSize
        else {
          throw untrusted("macho_build_version")
        }
        buildVersionCount += 1
      default:
        break
      }
      offset = commandEnd
    }
    guard offset == commandsEnd,
      mainCount == 1,
      dylinkerCount == 1,
      let codeSignatureRange,
      segmentRanges.contains(where: {
        $0.lowerBound <= codeSignatureRange.lowerBound
          && $0.upperBound >= codeSignatureRange.upperBound
      }),
      buildVersionCount == 1
    else {
      throw untrusted("macho_loader_closure")
    }
  }

  static func validateCodeAttestation(
    _ snapshot: CodeAttestationSnapshot,
    expectedExecutablePath: String
  ) throws {
    let staticCode = snapshot.staticCode
    let dynamicCode = snapshot.dynamicCode
    guard staticCode.identifier == signingIdentifier,
      dynamicCode.identifier == signingIdentifier,
      staticCode.teamIdentifier == signingTeamIdentifier,
      dynamicCode.teamIdentifier == signingTeamIdentifier,
      staticCode.identifier == dynamicCode.identifier,
      staticCode.teamIdentifier == dynamicCode.teamIdentifier,
      staticCode.unique == dynamicCode.unique,
      staticCode.canonicalExecutablePath == expectedExecutablePath,
      dynamicCode.canonicalExecutablePath == expectedExecutablePath,
      staticCode.canonicalExecutablePath
        == dynamicCode.canonicalExecutablePath
    else {
      throw untrusted("code_identity")
    }
    guard staticCode.flags & codeSignatureFlagRuntime != 0,
      staticCode.flags & codeSignatureFlagAdhoc == 0,
      staticCode.flags & codeSignatureFlagGetTaskAllow == 0,
      dynamicCode.flags & codeSignatureFlagRuntime != 0,
      dynamicCode.flags & codeSignatureFlagAdhoc == 0,
      dynamicCode.flags & codeSignatureFlagGetTaskAllow == 0
    else {
      throw untrusted("code_signature_flags")
    }
    guard let dynamicStatus = dynamicCode.dynamicStatus,
      dynamicStatus & codeSignatureStatusDebugged == 0
    else {
      throw untrusted("code_dynamic_status")
    }
    guard staticCode.entitlementKeys.isEmpty,
      dynamicCode.entitlementKeys.isEmpty
    else {
      throw untrusted("code_entitlements")
    }
  }

  private static func validateMachOLoaderPolicy(
    descriptor: Int32,
    byteCount: off_t
  ) throws {
    guard byteCount >= 32 else {
      throw untrusted("macho_thin_arm64")
    }
    let header = try preadExactly(
      descriptor: descriptor,
      byteCount: 32,
      offset: 0)
    let commandsByteCount = try exactInt(readUInt32(header, at: 20))
    guard commandsByteCount <= 4 * 1024 * 1024,
      let prefixByteCount = checkedAdd(32, commandsByteCount),
      UInt64(prefixByteCount) <= UInt64(byteCount)
    else {
      throw untrusted("macho_load_commands")
    }
    let prefix = try preadExactly(
      descriptor: descriptor,
      byteCount: prefixByteCount,
      offset: 0)
    try validateMachOLoaderPolicy(
      prefix,
      fileByteCount: UInt64(byteCount))
  }

  private static func securityCodeAttestation(
    executablePath: String
  ) throws -> CodeAttestationSnapshot {
    let validityFlags = SecCSFlags(rawValue: 0x2000_0011)
    let signingFlags = SecCSFlags(rawValue: 0x0000_0002)
    let requirement = try makeDeveloperIDApplicationRequirement()
    var staticCode: SecStaticCode?
    guard SecStaticCodeCreateWithPath(
      URL(fileURLWithPath: executablePath) as CFURL,
      SecCSFlags(rawValue: 0),
      &staticCode) == errSecSuccess,
      let staticCode
    else {
      throw untrusted("static_code")
    }
    guard SecStaticCodeCheckValidityWithErrors(
      staticCode,
      validityFlags,
      requirement,
      nil) == errSecSuccess
    else {
      throw untrusted("static_code_validity")
    }
    let currentProcess =
      try currentProcessDynamicCodeInformation()
    guard SecCodeCheckValidity(
      currentProcess.code,
      validityFlags,
      requirement) == errSecSuccess
    else {
      throw untrusted("dynamic_code_validity")
    }

    let staticIdentity = try codeIdentity(
      staticCode,
      signingFlags: signingFlags,
      requireDynamicStatus: false)
    let dynamicSigningIdentity = try codeIdentity(
      currentProcess.staticCodeView,
      signingFlags: signingFlags,
      requireDynamicStatus: false)
    let dynamicIdentity = CodeIdentitySnapshot(
      identifier: dynamicSigningIdentity.identifier,
      teamIdentifier: dynamicSigningIdentity.teamIdentifier,
      unique: dynamicSigningIdentity.unique,
      canonicalExecutablePath:
        dynamicSigningIdentity.canonicalExecutablePath,
      flags: currentProcess.status.flags,
      dynamicStatus: currentProcess.status.status,
      entitlementKeys:
        dynamicSigningIdentity.entitlementKeys)
    return CodeAttestationSnapshot(
      staticCode: staticIdentity,
      dynamicCode: dynamicIdentity)
  }

  static func makeDeveloperIDApplicationRequirement()
    throws -> SecRequirement
  {
    var requirement: SecRequirement?
    guard SecRequirementCreateWithString(
      developerIDApplicationRequirement as CFString,
      SecCSFlags(rawValue: 0),
      &requirement) == errSecSuccess,
      let requirement
    else {
      throw untrusted("code_requirement")
    }
    return requirement
  }

  static func currentProcessDynamicCodeStatusForTesting()
    throws -> DynamicCodeStatusSnapshot
  {
    try currentProcessDynamicCodeInformation().status
  }

  static func securityCodeAttestationForTesting(
    executablePath: String
  ) throws -> CodeAttestationSnapshot {
    try securityCodeAttestation(executablePath: executablePath)
  }

  private struct CurrentProcessDynamicCodeInformation {
    let code: SecCode
    let staticCodeView: SecStaticCode
    let status: DynamicCodeStatusSnapshot
  }

  private static func currentProcessDynamicCodeInformation()
    throws -> CurrentProcessDynamicCodeInformation
  {
    var dynamicCode: SecCode?
    guard SecCodeCopySelf(
      SecCSFlags(rawValue: 0),
      &dynamicCode) == errSecSuccess,
      let dynamicCode
    else {
      throw untrusted("dynamic_code")
    }
    // Security/SecCode.h documents that SecCodeCopySigningInformation accepts
    // either a SecCodeRef or SecStaticCodeRef. Its C declaration uses
    // SecStaticCodeRef, so Swift imports only that nominal type. Preserve the
    // dynamic SecCodeRef here because kSecCSDynamicInformation and
    // kSecCodeInfoStatus cannot be obtained from a static-only reference.
    let dynamicStaticCode = unsafeBitCast(
      dynamicCode,
      to: SecStaticCode.self)
    var rawInformation: CFDictionary?
    guard SecCodeCopySigningInformation(
      dynamicStaticCode,
      SecCSFlags(rawValue: 0x0000_0008),
      &rawInformation) == errSecSuccess,
      let information = rawInformation as? [CFString: Any],
      let flags = information[kSecCodeInfoFlags] as? NSNumber,
      let status = information[kSecCodeInfoStatus] as? NSNumber
    else {
      throw untrusted("code_dynamic_status")
    }
    return CurrentProcessDynamicCodeInformation(
      code: dynamicCode,
      staticCodeView: dynamicStaticCode,
      status: DynamicCodeStatusSnapshot(
        flags: flags.uint32Value,
        status: status.uint32Value))
  }

  private static func codeIdentity(
    _ code: SecStaticCode,
    signingFlags: SecCSFlags,
    requireDynamicStatus: Bool
  ) throws -> CodeIdentitySnapshot {
    var rawInformation: CFDictionary?
    guard SecCodeCopySigningInformation(
      code,
      signingFlags,
      &rawInformation) == errSecSuccess,
      let information = rawInformation as? [CFString: Any],
      let identifier = information[kSecCodeInfoIdentifier] as? String,
      let teamIdentifier =
        information[kSecCodeInfoTeamIdentifier] as? String,
      let unique = information[kSecCodeInfoUnique] as? Data,
      !unique.isEmpty,
      let executableURL =
        information[kSecCodeInfoMainExecutable] as? URL,
      let flagsNumber = information[kSecCodeInfoFlags] as? NSNumber
    else {
      throw untrusted("code_signing_information")
    }
    let entitlementKeys: Set<String>
    if let entitlements =
      information[kSecCodeInfoEntitlementsDict] as? [String: Any]
    {
      entitlementKeys = Set(entitlements.keys)
    } else if information[kSecCodeInfoEntitlements] != nil {
      throw untrusted("code_entitlements")
    } else {
      entitlementKeys = []
    }
    let dynamicStatus: UInt32?
    if requireDynamicStatus {
      guard let status =
        information[kSecCodeInfoStatus] as? NSNumber
      else {
        throw untrusted("code_dynamic_status")
      }
      dynamicStatus = status.uint32Value
    } else {
      dynamicStatus = nil
    }
    return CodeIdentitySnapshot(
      identifier: identifier,
      teamIdentifier: teamIdentifier,
      unique: unique,
      canonicalExecutablePath:
        executableURL.standardizedFileURL
          .resolvingSymlinksInPath().path,
      flags: flagsNumber.uint32Value,
      dynamicStatus: dynamicStatus,
      entitlementKeys: entitlementKeys)
  }

  private static func localAPFSIdentity(
    descriptor: Int32
  ) throws -> Data {
    var status = statfs()
    guard Darwin.fstatfs(descriptor, &status) == 0 else {
      throw untrusted("filesystem")
    }
    let fileSystemType = withUnsafePointer(
      to: &status.f_fstypename
    ) { pointer in
      pointer.withMemoryRebound(to: CChar.self, capacity: 16) {
        String(cString: $0)
      }
    }
    guard status.f_flags & UInt32(MNT_LOCAL) != 0,
      fileSystemType == "apfs"
    else {
      throw untrusted("filesystem")
    }
    return withUnsafeBytes(of: status.f_fsid) { Data($0) }
  }

  static func executableMetadataIsTrusted(
    _ status: stat,
    pathStatus: stat,
    expectedOwnerUID: uid_t,
    expectedGroupID: gid_t
  ) -> Bool {
    (status.st_mode & S_IFMT) == S_IFREG
      && status.st_uid == expectedOwnerUID
      && status.st_gid == expectedGroupID
      && (status.st_mode & 0o777) == 0o555
      && status.st_nlink == 1
      && status.st_size > 0
      && status.st_size <= maximumExecutableByteCount
      && status.st_dev == pathStatus.st_dev
      && status.st_ino == pathStatus.st_ino
  }

  private static func validateDirectory(
    descriptor: Int32,
    expectedOwnerUID: uid_t,
    field: String
  ) throws -> stat {
    var status = stat()
    guard Darwin.fstat(descriptor, &status) == 0,
      directoryMetadataIsTrusted(
        status,
        expectedOwnerUID: expectedOwnerUID)
    else {
      throw TatwoGoalRevisionRootAdminEnrollmentError
        .untrustedExecutable("directory_\(field)")
    }
    return status
  }

  static func directoryMetadataIsTrusted(
    _ status: stat,
    expectedOwnerUID: uid_t
  ) -> Bool {
    (status.st_mode & S_IFMT) == S_IFDIR
      && status.st_uid == expectedOwnerUID
      && (status.st_mode & 0o022) == 0
  }

  private static func validateNoExtendedACL(
    descriptor: Int32,
    field: String
  ) throws {
    errno = 0
    guard let acl = Darwin.acl_get_fd_np(
      descriptor,
      ACL_TYPE_EXTENDED)
    else {
      guard errno == ENOENT else {
        throw TatwoGoalRevisionRootAdminEnrollmentError
          .untrustedExecutable("acl_\(field)")
      }
      return
    }
    defer { _ = Darwin.acl_free(UnsafeMutableRawPointer(acl)) }
    throw TatwoGoalRevisionRootAdminEnrollmentError
      .untrustedExecutable("acl_\(field)")
  }

  private static func validateNoExtendedAttributes(
    descriptor: Int32,
    field: String
  ) throws {
    let byteCount = Darwin.flistxattr(descriptor, nil, 0, 0)
    guard byteCount >= 0,
      byteCount <= maximumExtendedAttributeListByteCount
    else {
      throw TatwoGoalRevisionRootAdminEnrollmentError
        .untrustedExecutable("xattr_\(field)")
    }
    guard byteCount > 0 else { return }
    var buffer = [CChar](
      repeating: 0,
      count: byteCount)
    let copiedCount = buffer.withUnsafeMutableBufferPointer { pointer in
      Darwin.flistxattr(
        descriptor,
        pointer.baseAddress,
        pointer.count,
        0)
    }
    guard copiedCount == byteCount else {
      throw TatwoGoalRevisionRootAdminEnrollmentError
        .untrustedExecutable("xattr_\(field)")
    }
    var start = 0
    var attributes: Set<String> = []
    while start < buffer.count {
      guard let terminator = buffer[start...].firstIndex(of: 0),
        terminator > start
      else {
        throw TatwoGoalRevisionRootAdminEnrollmentError
          .untrustedExecutable("xattr_\(field)")
      }
      let bytes = buffer[start..<terminator].map {
        UInt8(bitPattern: $0)
      }
      guard let attribute = String(bytes: bytes, encoding: .utf8),
        allowedExecutableExtendedAttributes.contains(attribute),
        attributes.insert(attribute).inserted
      else {
        throw TatwoGoalRevisionRootAdminEnrollmentError
          .untrustedExecutable("xattr_\(field)")
      }
      start = terminator + 1
    }
  }

  private static func sha256(
    descriptor: Int32,
    expectedSize: off_t
  ) throws -> String {
    var hasher = SHA256()
    var total: off_t = 0
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while total < expectedSize {
      let count = buffer.withUnsafeMutableBytes { bytes in
        Darwin.pread(
          descriptor,
          bytes.baseAddress,
          min(bytes.count, Int(expectedSize - total)),
          total)
      }
      if count < 0, errno == EINTR { continue }
      guard count > 0 else {
        throw TatwoGoalRevisionRootAdminEnrollmentError
          .untrustedExecutable("short_read")
      }
      hasher.update(data: Data(buffer.prefix(count)))
      total += off_t(count)
    }
    var trailing: UInt8 = 0
    while true {
      let count = Darwin.pread(
        descriptor,
        &trailing,
        1,
        expectedSize)
      if count < 0, errno == EINTR { continue }
      guard count == 0 else {
        throw TatwoGoalRevisionRootAdminEnrollmentError
          .untrustedExecutable("trailing_bytes")
      }
      break
    }
    return hasher.finalize().map {
      String(format: "%02x", $0)
    }.joined()
  }

  private static func preadExactly(
    descriptor: Int32,
    byteCount: Int,
    offset: off_t
  ) throws -> Data {
    guard byteCount >= 0 else {
      throw untrusted("macho_read")
    }
    var data = Data(count: byteCount)
    var total = 0
    while total < byteCount {
      let count = data.withUnsafeMutableBytes { bytes in
        Darwin.pread(
          descriptor,
          bytes.baseAddress?.advanced(by: total),
          byteCount - total,
          offset + off_t(total))
      }
      if count < 0, errno == EINTR { continue }
      guard count > 0 else {
        throw untrusted("macho_read")
      }
      total += count
    }
    return data
  }

  private static func loadCommandString(
    _ data: Data,
    commandOffset: Int,
    commandSize: Int,
    stringOffsetField: Int,
    minimumStringOffset: Int
  ) throws -> String {
    guard stringOffsetField >= 0,
      minimumStringOffset >= 0,
      let stringOffsetFieldEnd =
        checkedAdd(stringOffsetField, 4),
      stringOffsetFieldEnd <= commandSize,
      minimumStringOffset <= commandSize,
      let commandEnd =
        checkedAdd(commandOffset, commandSize),
      commandEnd <= data.count,
      let absoluteStringOffsetField =
        checkedAdd(commandOffset, stringOffsetField),
      let absoluteStringOffsetFieldEnd =
        checkedAdd(absoluteStringOffsetField, 4),
      absoluteStringOffsetFieldEnd <= commandEnd
    else {
      throw untrusted("macho_string")
    }
    let relativeOffset = try exactInt(
      readUInt32(data, at: absoluteStringOffsetField))
    guard relativeOffset >= minimumStringOffset,
      relativeOffset < commandSize,
      let start = checkedAdd(commandOffset, relativeOffset),
      let terminator =
        data[start..<commandEnd].firstIndex(of: 0),
      terminator > start,
      data[(terminator + 1)..<commandEnd]
        .allSatisfy({ $0 == 0 }),
      let value = String(
        bytes: data[start..<terminator],
        encoding: .utf8),
      !value.contains("\0")
    else {
      throw untrusted("macho_string")
    }
    return value
  }

  private static func fixedCString(
    _ data: Data,
    range: Range<Int>
  ) throws -> String {
    let bytes = data[range]
    let end = bytes.firstIndex(of: 0) ?? range.upperBound
    guard let value = String(
      bytes: data[range.lowerBound..<end],
      encoding: .utf8)
    else {
      throw untrusted("macho_string")
    }
    return value
  }

  private static func isCanonicalSystemDylibPath(
    _ path: String
  ) -> Bool {
    guard path.hasPrefix("/"),
      !path.hasSuffix("/"),
      !path.contains("//"),
      !path.contains("\0"),
      !path.contains("@")
    else {
      return false
    }
    let root: String
    if path.hasPrefix("/usr/lib/") {
      root = "/usr/lib/"
    } else if path.hasPrefix("/System/Library/Frameworks/") {
      root = "/System/Library/Frameworks/"
    } else {
      return false
    }
    let suffix = path.dropFirst(root.count)
    return !suffix.isEmpty
      && suffix.split(
        separator: "/",
        omittingEmptySubsequences: false
      ).allSatisfy {
        !$0.isEmpty && $0 != "." && $0 != ".."
      }
  }

  private static func readUInt32(
    _ data: Data,
    at offset: Int
  ) -> UInt32 {
    UInt32(data[offset])
      | UInt32(data[offset + 1]) << 8
      | UInt32(data[offset + 2]) << 16
      | UInt32(data[offset + 3]) << 24
  }

  private static func readUInt64(
    _ data: Data,
    at offset: Int
  ) -> UInt64 {
    UInt64(readUInt32(data, at: offset))
      | UInt64(readUInt32(data, at: offset + 4)) << 32
  }

  private static func exactInt(_ value: UInt32) throws -> Int {
    guard let result = Int(exactly: value) else {
      throw untrusted("macho_overflow")
    }
    return result
  }

  private static func checkedAdd(
    _ lhs: Int,
    _ rhs: Int
  ) -> Int? {
    let (result, overflow) = lhs.addingReportingOverflow(rhs)
    return overflow ? nil : result
  }

  private static func checkedAdd(
    _ lhs: UInt64,
    _ rhs: UInt64
  ) -> UInt64? {
    let (result, overflow) = lhs.addingReportingOverflow(rhs)
    return overflow ? nil : result
  }

  private static func checkedMultiply(
    _ lhs: Int,
    _ rhs: Int
  ) -> Int? {
    let (result, overflow) = lhs.multipliedReportingOverflow(by: rhs)
    return overflow ? nil : result
  }

  private static func checkedMultiply(
    _ lhs: UInt64,
    _ rhs: UInt64
  ) -> UInt64? {
    let (result, overflow) = lhs.multipliedReportingOverflow(by: rhs)
    return overflow ? nil : result
  }

  private static func untrusted(
    _ field: String
  ) -> TatwoGoalRevisionRootAdminEnrollmentError {
    .untrustedExecutable(field)
  }

  private static func directoryEvidence(
    component: String,
    status: stat
  ) -> String {
    [
      component,
      String(status.st_dev),
      String(status.st_ino),
      String(status.st_uid),
      String(status.st_gid),
      String(status.st_mode & 0o7777),
    ].joined(separator: ":")
  }

  private static func sameRevision(
    _ lhs: stat,
    _ rhs: stat
  ) -> Bool {
    lhs.st_dev == rhs.st_dev
      && lhs.st_ino == rhs.st_ino
      && lhs.st_mode == rhs.st_mode
      && lhs.st_uid == rhs.st_uid
      && lhs.st_gid == rhs.st_gid
      && lhs.st_nlink == rhs.st_nlink
      && lhs.st_size == rhs.st_size
      && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
      && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
      && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
      && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
  }

  private static func isCanonicalAbsolutePath(_ path: String) -> Bool {
    guard path.hasPrefix("/"),
      path == "/" || !path.hasSuffix("/"),
      !path.contains("//")
    else {
      return false
    }
    return path.split(
      separator: "/", omittingEmptySubsequences: true
    ).allSatisfy {
      $0 != "." && $0 != ".."
    }
  }

  private static func isSafeComponent(_ value: String) -> Bool {
    !value.isEmpty
      && value != "."
      && value != ".."
      && !value.contains("/")
      && !value.contains("\0")
  }

  private static func isLowercaseSHA256(_ value: String) -> Bool {
    value.count == 64
      && value.unicodeScalars.allSatisfy {
        ($0.value >= 48 && $0.value <= 57)
          || ($0.value >= 97 && $0.value <= 102)
      }
  }
  #endif
}
