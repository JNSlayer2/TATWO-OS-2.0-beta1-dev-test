import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Inputs accepted by the explicit root-admin enrollment command. No caller
/// can override the canonical user state root or the production grant root.
@_spi(TatwoBootstrapRecoveryHost)
public struct TatwoGoalRevisionRootAdminEnrollmentRequestV1:
  Sendable, Equatable
{
  public let successorContractID: String
  public let threadID: String
  public let turnID: String
  public let eventID: String
  public let humanMessageSourcePath: String
  public let legacyUnavailableEvidenceSourcePath: String
  public let legacyAppVersion: String
  public let legacyAppBuild: String
  public let deviceID: String
  public let ttlSeconds: UInt64

  public init(
    successorContractID: String,
    threadID: String,
    turnID: String,
    eventID: String,
    humanMessageSourcePath: String,
    legacyUnavailableEvidenceSourcePath: String,
    legacyAppVersion: String,
    legacyAppBuild: String,
    deviceID: String,
    ttlSeconds: UInt64 = 600
  ) {
    self.successorContractID = successorContractID
    self.threadID = threadID
    self.turnID = turnID
    self.eventID = eventID
    self.humanMessageSourcePath = humanMessageSourcePath
    self.legacyUnavailableEvidenceSourcePath =
      legacyUnavailableEvidenceSourcePath
    self.legacyAppVersion = legacyAppVersion
    self.legacyAppBuild = legacyAppBuild
    self.deviceID = deviceID
    self.ttlSeconds = ttlSeconds
  }
}

@_spi(TatwoBootstrapRecoveryHost)
public struct TatwoGoalRevisionRootAdminEnrollmentResultV1:
  Codable, Sendable, Equatable
{
  public let schema: String
  public let mutationPerformed: Bool
  public let grantInstalled: Bool
  public let goalMutationPerformed: Bool
  public let grantConsumed: Bool
  public let authorizationCreated: Bool
  public let targetPath: String
  public let grantBodyDigest: String
  public let grantFileDigest: String
  public let grantByteCount: Int
  public let shortCode: String
  public let localUserUID: UInt32
  public let enrollmentExecutablePath: String
  public let enrollmentExecutableSHA256: String
  public let enrollmentExecutableParentChainDigest: String
  public let humanMessageDigest: String
  public let legacyUnavailableEvidenceDigest: String
  public let oldContractID: String
  public let oldGoalID: String
  public let newContractID: String
  public let newGoalID: String
  public let issuedAt: Date
  public let expiresAt: Date
  public let nextHumanGate: String
}

@_spi(TatwoBootstrapRecoveryHost)
public enum TatwoGoalRevisionRootAdminEnrollmentError:
  Error, LocalizedError, Equatable, Sendable
{
  case unavailableOnPlatform
  case effectiveRootRequired
  case sudoUIDRequired
  case invalidSudoUID
  case invalidUserHome
  case untrustedExecutable(String)
  case invalidInput(String)
  case invalidSource(String)
  case ttyUnavailable
  case confirmationMismatch
  case candidateChanged
  case candidateExpired
  case invalidTarget(String)
  case targetAlreadyExists
  case targetWriteFailed(String)

  public var errorDescription: String? {
    switch self {
    case .unavailableOnPlatform:
      return "Root-admin Goal revision enrollment is available only on macOS."
    case .effectiveRootRequired:
      return
        "This command must already be running as root; it never invokes sudo automatically."
    case .sudoUIDRequired:
      return
        "SUDO_UID is required so the command can bind the grant to the invoking local user."
    case .invalidSudoUID:
      return "SUDO_UID does not identify a supported non-root local user."
    case .invalidUserHome:
      return "The invoking local user's fixed home directory is invalid."
    case .untrustedExecutable(let field):
      return
        "Root-admin enrollment must run from the exact root-owned, content-addressed executable: \(field)"
    case .invalidInput(let field):
      return "Root-admin enrollment input is invalid: \(field)"
    case .invalidSource(let field):
      return "Root-admin enrollment source file is invalid: \(field)"
    case .ttyUnavailable:
      return
        "A real /dev/tty is required for the fresh root-admin review and exact short-code confirmation."
    case .confirmationMismatch:
      return "The entered short code did not exactly match the displayed code."
    case .candidateChanged:
      return
        "The source files or canonical Goal/session candidate changed during admin review."
    case .candidateExpired:
      return "The reviewed recovery candidate expired before installation."
    case .invalidTarget(let field):
      return "The fixed root-owned grant target is invalid: \(field)"
    case .targetAlreadyExists:
      return
        "The exact root-owned grant target already exists; enrollment will not overwrite it."
    case .targetWriteFailed(let field):
      return "The root-owned grant could not be durably installed: \(field)"
    }
  }
}

/// The only production writer for a root-owned Goal revision recovery grant.
///
/// It deliberately performs only enrollment. It does not consume the grant,
/// create a promotion authorization, transition either Goal, or update the
/// current-session pointer.
@_spi(TatwoBootstrapRecoveryHost)
public enum TatwoGoalRevisionRootAdminEnrollment {
  public static func enrollProduction(
    request: TatwoGoalRevisionRootAdminEnrollmentRequestV1
  ) throws -> TatwoGoalRevisionRootAdminEnrollmentResultV1 {
    #if os(macOS)
    guard Darwin.geteuid() == 0 else {
      throw TatwoGoalRevisionRootAdminEnrollmentError
        .effectiveRootRequired
    }
    guard
      let rawSudoUID = ProcessInfo.processInfo.environment["SUDO_UID"],
      !rawSudoUID.isEmpty
    else {
      throw TatwoGoalRevisionRootAdminEnrollmentError.sudoUIDRequired
    }
    guard let parsed = UInt32(rawSudoUID), parsed > 0 else {
      throw TatwoGoalRevisionRootAdminEnrollmentError.invalidSudoUID
    }
    let localUID = uid_t(parsed)
    guard let passwordRecord = Darwin.getpwuid(localUID),
      passwordRecord.pointee.pw_uid == localUID,
      let homeCString = passwordRecord.pointee.pw_dir
    else {
      throw TatwoGoalRevisionRootAdminEnrollmentError.invalidSudoUID
    }
    let homePath = String(cString: homeCString)
    guard Self.isCanonicalAbsolutePath(homePath), homePath != "/" else {
      throw TatwoGoalRevisionRootAdminEnrollmentError.invalidUserHome
    }
    let homeURL = URL(fileURLWithPath: homePath, isDirectory: true)
    let stateDirectoryURL = homeURL
      .appendingPathComponent("Library", isDirectory: true)
      .appendingPathComponent("Application Support", isDirectory: true)
      .appendingPathComponent("Tatwo Ultrawork", isDirectory: true)
      .appendingPathComponent("state", isDirectory: true)
    let executableProvenance =
      try TatwoGoalRevisionRootAdminExecutableProvenance
      .validateCurrentProcess()

    let tty = try TatwoGoalRevisionRootAdminTTY.openProduction()
    defer { tty.close() }
    return try perform(
      request: request,
      context: TatwoGoalRevisionRootAdminEnrollmentContext(
        effectiveUID: 0,
        sudoUID: localUID,
        stateDirectoryURL: stateDirectoryURL,
        sourceExpectedOwnerUID: localUID,
        targetRootURL: URL(fileURLWithPath: "/", isDirectory: true),
        targetDirectoryComponents:
          TatwoGoalRevisionRootAdminEnrollmentContext
          .productionDirectoryComponents,
        targetExpectedOwnerUID: 0,
        targetExpectedGroupID: 0,
        executableProvenance: executableProvenance,
        clock: Date.init,
        writeReview: { try tty.write($0) },
        readConfirmation: { try tty.readLine() }))
    #else
    throw TatwoGoalRevisionRootAdminEnrollmentError.unavailableOnPlatform
    #endif
  }

  static func perform(
    request: TatwoGoalRevisionRootAdminEnrollmentRequestV1,
    context: TatwoGoalRevisionRootAdminEnrollmentContext
  ) throws -> TatwoGoalRevisionRootAdminEnrollmentResultV1 {
    #if os(macOS)
    guard context.effectiveUID == 0 else {
      throw TatwoGoalRevisionRootAdminEnrollmentError
        .effectiveRootRequired
    }
    guard context.sudoUID > 0,
      context.sudoUID == context.sourceExpectedOwnerUID
    else {
      throw TatwoGoalRevisionRootAdminEnrollmentError.invalidSudoUID
    }
    guard request.ttlSeconds > 0, request.ttlSeconds <= 30 * 60 else {
      throw TatwoGoalRevisionRootAdminEnrollmentError
        .invalidInput("ttlSeconds")
    }

    let issuedAt =
      TatwoGoalRevisionBootstrapRecoveryEvidenceV1.wholeSecond(
        context.clock())
    let expiresAt = issuedAt.addingTimeInterval(
      TimeInterval(request.ttlSeconds))
    let first = try prepareCandidate(
      request: request,
      context: context,
      issuedAt: issuedAt,
      expiresAt: expiresAt)
    guard first.prepared.plan.evidence.localUserUID
      == UInt32(context.sudoUID)
    else {
      throw TatwoGoalRevisionRootAdminEnrollmentError.invalidSudoUID
    }

    let reviewedFileName =
      try TatwoGoalRevisionRootOwnedRecoveryGrantPlanV1.fileName(
        bodyDigest: first.prepared.plan.grant.bodyDigest)
    let reviewedTargetPath = targetPath(
      rootURL: context.targetRootURL,
      directoryComponents: context.targetDirectoryComponents,
      fileName: reviewedFileName)
    if context.targetRootURL.path == "/",
      context.targetDirectoryComponents
        == TatwoGoalRevisionRootAdminEnrollmentContext
          .productionDirectoryComponents,
      reviewedTargetPath != first.prepared.plan.targetPath
    {
      throw TatwoGoalRevisionRootAdminEnrollmentError
        .invalidTarget("production_path_binding")
    }
    let review = try renderReview(
      request: request,
      candidate: first,
      targetPath: reviewedTargetPath,
      executableProvenance: context.executableProvenance)
    try context.writeReview(Data(review.utf8))
    let confirmation = try context.readConfirmation()
    guard confirmation == first.prepared.plan.evidence.shortCode else {
      throw TatwoGoalRevisionRootAdminEnrollmentError.confirmationMismatch
    }

    let second = try prepareCandidate(
      request: request,
      context: context,
      issuedAt: issuedAt,
      expiresAt: expiresAt)
    guard first == second else {
      throw TatwoGoalRevisionRootAdminEnrollmentError.candidateChanged
    }
    guard context.clock() < expiresAt else {
      throw TatwoGoalRevisionRootAdminEnrollmentError.candidateExpired
    }

    let installedPath = try installGrant(
      bytes: second.prepared.plan.canonicalGrantBytes,
      fileName: reviewedFileName,
      context: context)
    let evidence = second.prepared.plan.evidence
    return TatwoGoalRevisionRootAdminEnrollmentResultV1(
      schema: "TatwoGoalRevisionRootAdminEnrollmentResultV1",
      mutationPerformed: true,
      grantInstalled: true,
      goalMutationPerformed: false,
      grantConsumed: false,
      authorizationCreated: false,
      targetPath: installedPath,
      grantBodyDigest: second.prepared.plan.grant.bodyDigest,
      grantFileDigest: second.prepared.plan.grantFileDigest,
      grantByteCount: second.prepared.plan.canonicalGrantBytes.count,
      shortCode: evidence.shortCode,
      localUserUID: evidence.localUserUID,
      enrollmentExecutablePath:
        context.executableProvenance.executablePath,
      enrollmentExecutableSHA256:
        context.executableProvenance.executableSHA256,
      enrollmentExecutableParentChainDigest:
        context.executableProvenance.parentChainDigest,
      humanMessageDigest: evidence.humanMessageDigest,
      legacyUnavailableEvidenceDigest:
        evidence.legacyUnavailableEvidenceDigest,
      oldContractID: evidence.oldContractID,
      oldGoalID: evidence.oldGoalID,
      newContractID: evidence.newContractID,
      newGoalID: evidence.newGoalID,
      issuedAt: evidence.issuedAt,
      expiresAt: evidence.expiresAt,
      nextHumanGate:
        "Enrollment only is complete. Do not consume this grant, create the "
        + "promotion authorization, or transition the Goal until a separate "
        + "fresh action-time human confirmation authorizes that step.")
    #else
    throw TatwoGoalRevisionRootAdminEnrollmentError.unavailableOnPlatform
    #endif
  }

  #if os(macOS)
  private struct SourceSnapshot: Equatable {
    let path: String
    let data: Data
    let ownerUID: uid_t
    let groupID: gid_t
    let permissions: mode_t
    let device: dev_t
    let inode: ino_t
    let size: off_t
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64
    let parentChainDigest: String
  }

  private struct Candidate: Equatable {
    let humanMessage: SourceSnapshot
    let legacyUnavailableEvidence: SourceSnapshot
    let prepared:
      TatwoGoalRevisionBootstrapRecoveryPreparedChallengeV1
  }

  private static func prepareCandidate(
    request: TatwoGoalRevisionRootAdminEnrollmentRequestV1,
    context: TatwoGoalRevisionRootAdminEnrollmentContext,
    issuedAt: Date,
    expiresAt: Date
  ) throws -> Candidate {
    let human = try readSource(
      path: request.humanMessageSourcePath,
      expectedOwnerUID: context.sourceExpectedOwnerUID,
      field: "human_message")
    let legacy = try readSource(
      path: request.legacyUnavailableEvidenceSourcePath,
      expectedOwnerUID: context.sourceExpectedOwnerUID,
      field: "legacy_unavailable_evidence")
    let goalStore = TatwoGoalRunStore(
      directoryURL: context.stateDirectoryURL)
    let prepared =
      try TatwoGoalRevisionBootstrapRecoveryChallengeFactory
      .prepareDetailed(
        input: TatwoGoalRevisionBootstrapRecoveryChallengeInputV1(
          successorContractID: request.successorContractID,
          threadID: request.threadID,
          turnID: request.turnID,
          eventID: request.eventID,
          humanMessage: human.data,
          legacyAppVersion: request.legacyAppVersion,
          legacyAppBuild: request.legacyAppBuild,
          legacyUnavailableEvidence: legacy.data,
          deviceID: request.deviceID,
          localUserUID: UInt32(context.sudoUID),
          issuedAt: issuedAt,
          expiresAt: expiresAt),
        goalStore: goalStore,
        sessionStore: TatwoSessionStore(
          directoryURL: context.stateDirectoryURL),
        dispatchRegistry: TatwoDispatchRegistry(
          directoryURL: context.stateDirectoryURL))
    return Candidate(
      humanMessage: human,
      legacyUnavailableEvidence: legacy,
      prepared: prepared)
  }

  private static func readSource(
    path: String,
    expectedOwnerUID: uid_t,
    field: String
  ) throws -> SourceSnapshot {
    guard isCanonicalAbsolutePath(path) else {
      throw TatwoGoalRevisionRootAdminEnrollmentError
        .invalidSource("\(field)_path")
    }
    let components = path.split(
      separator: "/", omittingEmptySubsequences: true
    ).map(String.init)
    guard !components.isEmpty,
      components.allSatisfy(isSafeComponent)
    else {
      throw TatwoGoalRevisionRootAdminEnrollmentError
        .invalidSource("\(field)_path_components")
    }
    var currentFD = Darwin.open(
      "/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard currentFD >= 0 else {
      throw TatwoGoalRevisionRootAdminEnrollmentError
        .invalidSource("\(field)_root")
    }
    defer { _ = Darwin.close(currentFD) }
    var parentEvidence: [String] = []
    var rootStatus = stat()
    guard Darwin.fstat(currentFD, &rootStatus) == 0,
      (rootStatus.st_mode & S_IFMT) == S_IFDIR
    else {
      throw TatwoGoalRevisionRootAdminEnrollmentError
        .invalidSource("\(field)_root_metadata")
    }
    parentEvidence.append(
      Self.directoryEvidence(
        component: "/",
        status: rootStatus))
    for component in components.dropLast() {
      let nextFD = component.withCString {
        Darwin.openat(
          currentFD,
          $0,
          O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      }
      guard nextFD >= 0 else {
        throw TatwoGoalRevisionRootAdminEnrollmentError
          .invalidSource("\(field)_parent_\(component)")
      }
      var directoryStatus = stat()
      guard Darwin.fstat(nextFD, &directoryStatus) == 0,
        (directoryStatus.st_mode & S_IFMT) == S_IFDIR
      else {
        _ = Darwin.close(nextFD)
        throw TatwoGoalRevisionRootAdminEnrollmentError
          .invalidSource("\(field)_parent_metadata_\(component)")
      }
      parentEvidence.append(
        Self.directoryEvidence(
          component: component,
          status: directoryStatus))
      _ = Darwin.close(currentFD)
      currentFD = nextFD
    }
    let leaf = components[components.count - 1]
    var pathStatus = stat()
    guard leaf.withCString({
      Darwin.fstatat(
        currentFD,
        $0,
        &pathStatus,
        AT_SYMLINK_NOFOLLOW)
    }) == 0,
      (pathStatus.st_mode & S_IFMT) == S_IFREG
    else {
      throw TatwoGoalRevisionRootAdminEnrollmentError
        .invalidSource("\(field)_leaf")
    }
    let descriptor = leaf.withCString {
      Darwin.openat(
        currentFD,
        $0,
        O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    }
    guard descriptor >= 0 else {
      throw TatwoGoalRevisionRootAdminEnrollmentError
        .invalidSource("\(field)_open")
    }
    defer { _ = Darwin.close(descriptor) }
    var before = stat()
    guard Darwin.fstat(descriptor, &before) == 0,
      (before.st_mode & S_IFMT) == S_IFREG,
      before.st_uid == expectedOwnerUID,
      (before.st_mode & 0o022) == 0,
      before.st_nlink == 1,
      before.st_size > 0,
      before.st_size <= 1024 * 1024,
      before.st_dev == pathStatus.st_dev,
      before.st_ino == pathStatus.st_ino
    else {
      throw TatwoGoalRevisionRootAdminEnrollmentError
        .invalidSource("\(field)_metadata")
    }
    let data = try readExactly(
      descriptor: descriptor,
      expectedSize: Int(before.st_size),
      field: field)
    var after = stat()
    var pathAfter = stat()
    guard Darwin.fstat(descriptor, &after) == 0,
      sameSourceRevision(before, after),
      leaf.withCString({
        Darwin.fstatat(
          currentFD,
          $0,
          &pathAfter,
          AT_SYMLINK_NOFOLLOW)
      }) == 0,
      sameSourceRevision(pathStatus, pathAfter),
      let text = String(data: data, encoding: .utf8),
      isSafeTTYText(text, allowLineBreaks: true)
    else {
      throw TatwoGoalRevisionRootAdminEnrollmentError
        .invalidSource("\(field)_changed_or_encoding")
    }
    return SourceSnapshot(
      path: path,
      data: data,
      ownerUID: before.st_uid,
      groupID: before.st_gid,
      permissions: before.st_mode & 0o7777,
      device: before.st_dev,
      inode: before.st_ino,
      size: before.st_size,
      modifiedSeconds: Int64(before.st_mtimespec.tv_sec),
      modifiedNanoseconds: Int64(before.st_mtimespec.tv_nsec),
      changedSeconds: Int64(before.st_ctimespec.tv_sec),
      changedNanoseconds: Int64(before.st_ctimespec.tv_nsec),
      parentChainDigest:
        TatwoGoalRevisionBootstrapRecoveryEvidenceV1.digest(
          Data(parentEvidence.joined(separator: "\n").utf8)))
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

  private static func sameSourceRevision(
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

  private static func readExactly(
    descriptor: Int32,
    expectedSize: Int,
    field: String
  ) throws -> Data {
    var result = Data()
    result.reserveCapacity(expectedSize)
    var buffer = [UInt8](
      repeating: 0,
      count: max(1, min(16 * 1024, expectedSize)))
    while result.count < expectedSize {
      let remaining = expectedSize - result.count
      let count = buffer.withUnsafeMutableBytes { bytes in
        Darwin.read(
          descriptor,
          bytes.baseAddress,
          min(bytes.count, remaining))
      }
      if count < 0, errno == EINTR { continue }
      guard count > 0 else {
        throw TatwoGoalRevisionRootAdminEnrollmentError
          .invalidSource("\(field)_short_read")
      }
      result.append(contentsOf: buffer.prefix(count))
    }
    var trailing: UInt8 = 0
    while true {
      let count = Darwin.read(descriptor, &trailing, 1)
      if count < 0, errno == EINTR { continue }
      guard count == 0 else {
        throw TatwoGoalRevisionRootAdminEnrollmentError
          .invalidSource("\(field)_trailing_bytes")
      }
      break
    }
    return result
  }

  private static func renderReview(
    request: TatwoGoalRevisionRootAdminEnrollmentRequestV1,
    candidate: Candidate,
    targetPath: String,
    executableProvenance:
      TatwoGoalRevisionRootAdminExecutableProvenanceV1
  ) throws -> String {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    func json<T: Encodable>(_ value: T) throws -> String {
      guard let rendered = String(
        data: try encoder.encode(value),
        encoding: .utf8)
      else {
        throw TatwoGoalRevisionRootAdminEnrollmentError
          .invalidInput("review_json")
      }
      return rendered
    }
    let humanText = String(
      decoding: candidate.humanMessage.data,
      as: UTF8.self)
    let legacyText = String(
      decoding: candidate.legacyUnavailableEvidence.data,
      as: UTF8.self)
    let sessionJSON = try json(
      candidate.prepared.canonicalCurrentSession)
    let oldJSON = try json(
      candidate.prepared.canonicalPredecessorGoal)
    let newJSON = try json(
      candidate.prepared.canonicalSuccessorGoal)
    let plan = candidate.prepared.plan
    let evidence = plan.evidence
    return """

      ================================================================================
      TATWO GOAL REVISION ROOT-ADMIN ENROLLMENT — FRESH HUMAN REVIEW REQUIRED
      ================================================================================
      This command WILL ONLY install one exact root-owned, single-use grant.
      It WILL NOT consume the grant, create an authorization, transition a Goal,
      update current-session, invoke sudo, sign, build, deploy, commit, or push.

      Invoking local UID: \(evidence.localUserUID)
      Enrollment executable: \(executableProvenance.executablePath)
      Enrollment executable SHA-256: \(executableProvenance.executableSHA256)
      Enrollment executable parent-chain digest: \(executableProvenance.parentChainDigest)
      Thread ID: \(evidence.threadID)
      Turn ID: \(evidence.turnID)
      Event ID: \(evidence.eventID)
      Device ID: \(evidence.deviceID)
      Successor requested: \(request.successorContractID)
      Recovery reason: \(evidence.recoveryReason)
      Legacy App: \(evidence.legacyAppVersion) build \(evidence.legacyAppBuild)
      Fixed target: \(targetPath)
      Grant body digest: \(plan.grant.bodyDigest)
      Grant file digest: \(plan.grantFileDigest)
      Grant byte count: \(plan.canonicalGrantBytes.count)
      Exact short code: \(evidence.shortCode)
      Issued at: \(evidence.issuedAt)
      Expires at: \(evidence.expiresAt)

      --------------------------------------------------------------------------------
      COMPLETE HUMAN MESSAGE SOURCE
      path: \(candidate.humanMessage.path)
      owner uid: \(candidate.humanMessage.ownerUID)
      verified leaf dev/inode: \(candidate.humanMessage.device)/\(candidate.humanMessage.inode)
      verified parent chain digest: \(candidate.humanMessage.parentChainDigest)
      bytes: \(candidate.humanMessage.data.count)
      digest: \(evidence.humanMessageDigest)
      --------------------------------------------------------------------------------
      \(humanText)
      --------------------------------------------------------------------------------
      END COMPLETE HUMAN MESSAGE SOURCE

      --------------------------------------------------------------------------------
      COMPLETE LEGACY UNAVAILABLE EVIDENCE SOURCE
      path: \(candidate.legacyUnavailableEvidence.path)
      owner uid: \(candidate.legacyUnavailableEvidence.ownerUID)
      verified leaf dev/inode: \(candidate.legacyUnavailableEvidence.device)/\(candidate.legacyUnavailableEvidence.inode)
      verified parent chain digest: \(candidate.legacyUnavailableEvidence.parentChainDigest)
      bytes: \(candidate.legacyUnavailableEvidence.data.count)
      digest: \(evidence.legacyUnavailableEvidenceDigest)
      --------------------------------------------------------------------------------
      \(legacyText)
      --------------------------------------------------------------------------------
      END COMPLETE LEGACY UNAVAILABLE EVIDENCE SOURCE

      --------------------------------------------------------------------------------
      CANONICAL CURRENT SESSION — FULL RECORD
      revision digest: \(candidate.prepared.currentSessionRevisionDigest)
      --------------------------------------------------------------------------------
      \(escapeUnsafeTTYScalars(sessionJSON))

      --------------------------------------------------------------------------------
      OLD GOAL — FULL CANONICAL RECORD
      persisted revision digest: \(candidate.prepared.predecessorPersistedRevisionDigest)
      --------------------------------------------------------------------------------
      \(escapeUnsafeTTYScalars(oldJSON))

      --------------------------------------------------------------------------------
      NEW GOAL — FULL CANONICAL RECORD
      persisted revision digest: \(candidate.prepared.successorPersistedRevisionDigest)
      --------------------------------------------------------------------------------
      \(escapeUnsafeTTYScalars(newJSON))

      --------------------------------------------------------------------------------
      COMPLETE OLD/NEW GOAL LINE DIFF
      --------------------------------------------------------------------------------
      \(completeLineDiff(
        old: escapeUnsafeTTYScalars(oldJSON),
        new: escapeUnsafeTTYScalars(newJSON)))

      Re-check every section above. To install ONLY the exact grant shown above,
      enter the exact short code \(evidence.shortCode) and press Return:
      """
  }

  private static func completeLineDiff(
    old: String,
    new: String
  ) -> String {
    let oldLines = old.split(
      separator: "\n", omittingEmptySubsequences: false)
    let newLines = new.split(
      separator: "\n", omittingEmptySubsequences: false)
    var result: [String] = []
    result.reserveCapacity(oldLines.count + newLines.count)
    for index in 0..<max(oldLines.count, newLines.count) {
      let oldLine = index < oldLines.count ? String(oldLines[index]) : nil
      let newLine = index < newLines.count ? String(newLines[index]) : nil
      if oldLine == newLine, let oldLine {
        result.append("  \(oldLine)")
      } else {
        if let oldLine { result.append("- \(oldLine)") }
        if let newLine { result.append("+ \(newLine)") }
      }
    }
    return result.joined(separator: "\n")
  }

  private static func installGrant(
    bytes: Data,
    fileName: String,
    context: TatwoGoalRevisionRootAdminEnrollmentContext
  ) throws -> String {
    guard isSafeComponent(fileName),
      !context.targetDirectoryComponents.isEmpty,
      context.targetDirectoryComponents.allSatisfy(isSafeComponent)
    else {
      throw TatwoGoalRevisionRootAdminEnrollmentError
        .invalidTarget("path")
    }
    let rootFD = context.targetRootURL.path.withCString {
      Darwin.open(
        $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    }
    guard rootFD >= 0 else {
      throw TatwoGoalRevisionRootAdminEnrollmentError
        .invalidTarget("root_open")
    }
    defer { _ = Darwin.close(rootFD) }
    try validateDirectory(
      descriptor: rootFD,
      expectedOwnerUID: context.targetExpectedOwnerUID,
      field: "root")

    var currentFD = Darwin.dup(rootFD)
    guard currentFD >= 0 else {
      throw TatwoGoalRevisionRootAdminEnrollmentError
        .invalidTarget("root_dup")
    }
    defer { _ = Darwin.close(currentFD) }
    for component in context.targetDirectoryComponents {
      var nextFD = component.withCString {
        Darwin.openat(
          currentFD,
          $0,
          O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      }
      if nextFD < 0, errno == ENOENT {
        let created = component.withCString {
          Darwin.mkdirat(currentFD, $0, 0o755)
        }
        guard created == 0 else {
          throw TatwoGoalRevisionRootAdminEnrollmentError
            .invalidTarget("mkdir_\(component)")
        }
        nextFD = component.withCString {
          Darwin.openat(
            currentFD,
            $0,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard nextFD >= 0,
          Darwin.fchown(
            nextFD,
            context.targetExpectedOwnerUID,
            context.targetExpectedGroupID) == 0,
          Darwin.fchmod(nextFD, 0o755) == 0,
          Darwin.fsync(nextFD) == 0,
          Darwin.fsync(currentFD) == 0
        else {
          if nextFD >= 0 { _ = Darwin.close(nextFD) }
          throw TatwoGoalRevisionRootAdminEnrollmentError
            .invalidTarget("initialize_\(component)")
        }
      }
      guard nextFD >= 0 else {
        throw TatwoGoalRevisionRootAdminEnrollmentError
          .invalidTarget("open_\(component)")
      }
      do {
        try validateDirectory(
          descriptor: nextFD,
          expectedOwnerUID: context.targetExpectedOwnerUID,
          field: component)
      } catch {
        _ = Darwin.close(nextFD)
        throw error
      }
      _ = Darwin.close(currentFD)
      currentFD = nextFD
    }

    let fileFD = fileName.withCString {
      Darwin.openat(
        currentFD,
        $0,
        O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
        0o400)
    }
    guard fileFD >= 0 else {
      if errno == EEXIST {
        throw TatwoGoalRevisionRootAdminEnrollmentError
          .targetAlreadyExists
      }
      throw TatwoGoalRevisionRootAdminEnrollmentError
        .targetWriteFailed("create")
    }
    var committed = false
    defer {
      _ = Darwin.close(fileFD)
      if !committed {
        _ = fileName.withCString {
          Darwin.unlinkat(currentFD, $0, 0)
        }
        _ = Darwin.fsync(currentFD)
      }
    }
    guard Darwin.fchown(
      fileFD,
      context.targetExpectedOwnerUID,
      context.targetExpectedGroupID) == 0
    else {
      throw TatwoGoalRevisionRootAdminEnrollmentError
        .targetWriteFailed("chown")
    }
    try writeAll(descriptor: fileFD, data: bytes)
    guard Darwin.fchmod(fileFD, 0o444) == 0,
      Darwin.fsync(fileFD) == 0,
      Darwin.lseek(fileFD, 0, SEEK_SET) == 0
    else {
      throw TatwoGoalRevisionRootAdminEnrollmentError
        .targetWriteFailed("durability")
    }
    let readback = try readGrantExactly(
      descriptor: fileFD,
      expectedSize: bytes.count)
    var status = stat()
    guard readback == bytes,
      Darwin.fstat(fileFD, &status) == 0,
      (status.st_mode & S_IFMT) == S_IFREG,
      status.st_uid == context.targetExpectedOwnerUID,
      status.st_gid == context.targetExpectedGroupID,
      (status.st_mode & 0o777) == 0o444,
      status.st_nlink == 1,
      status.st_size == off_t(bytes.count),
      Darwin.fsync(currentFD) == 0
    else {
      throw TatwoGoalRevisionRootAdminEnrollmentError
        .targetWriteFailed("readback")
    }
    committed = true
    return targetPath(
      rootURL: context.targetRootURL,
      directoryComponents: context.targetDirectoryComponents,
      fileName: fileName)
  }

  private static func validateDirectory(
    descriptor: Int32,
    expectedOwnerUID: uid_t,
    field: String
  ) throws {
    var status = stat()
    guard Darwin.fstat(descriptor, &status) == 0,
      (status.st_mode & S_IFMT) == S_IFDIR,
      status.st_uid == expectedOwnerUID,
      (status.st_mode & 0o022) == 0
    else {
      throw TatwoGoalRevisionRootAdminEnrollmentError
        .invalidTarget("directory_\(field)")
    }
  }

  private static func writeAll(
    descriptor: Int32,
    data: Data
  ) throws {
    try data.withUnsafeBytes { bytes in
      var offset = 0
      while offset < bytes.count {
        let count = Darwin.write(
          descriptor,
          bytes.baseAddress?.advanced(by: offset),
          bytes.count - offset)
        if count < 0, errno == EINTR { continue }
        guard count > 0 else {
          throw TatwoGoalRevisionRootAdminEnrollmentError
            .targetWriteFailed("write")
        }
        offset += count
      }
    }
  }

  private static func readGrantExactly(
    descriptor: Int32,
    expectedSize: Int
  ) throws -> Data {
    var result = Data()
    result.reserveCapacity(expectedSize)
    var buffer = [UInt8](
      repeating: 0,
      count: max(1, min(4096, expectedSize)))
    while result.count < expectedSize {
      let count = buffer.withUnsafeMutableBytes {
        Darwin.read(
          descriptor,
          $0.baseAddress,
          min($0.count, expectedSize - result.count))
      }
      if count < 0, errno == EINTR { continue }
      guard count > 0 else {
        throw TatwoGoalRevisionRootAdminEnrollmentError
          .targetWriteFailed("short_readback")
      }
      result.append(contentsOf: buffer.prefix(count))
    }
    var trailing: UInt8 = 0
    let trailingCount = Darwin.read(descriptor, &trailing, 1)
    guard trailingCount == 0 else {
      throw TatwoGoalRevisionRootAdminEnrollmentError
        .targetWriteFailed("trailing_readback")
    }
    return result
  }

  private static func targetPath(
    rootURL: URL,
    directoryComponents: [String],
    fileName: String
  ) -> String {
    var result = rootURL
    for component in directoryComponents {
      result.appendPathComponent(component, isDirectory: true)
    }
    result.appendPathComponent(fileName, isDirectory: false)
    return result.path
  }

  private static func isCanonicalAbsolutePath(_ path: String) -> Bool {
    guard path.hasPrefix("/"),
      path == "/" || !path.hasSuffix("/"),
      !path.contains("//"),
      isSafeTTYText(path, allowLineBreaks: false)
    else {
      return false
    }
    return path.split(
      separator: "/", omittingEmptySubsequences: true
    ).allSatisfy {
      $0 != "." && $0 != ".."
    }
  }

  private static func isSafeTTYText(
    _ value: String,
    allowLineBreaks: Bool
  ) -> Bool {
    value.unicodeScalars.allSatisfy { scalar in
      let code = scalar.value
      if allowLineBreaks, code == 0x09 || code == 0x0A {
        return true
      }
      if code < 0x20 || code == 0x7F || (0x80...0x9F).contains(code) {
        return false
      }
      if (0x202A...0x202E).contains(code)
        || (0x2066...0x2069).contains(code)
      {
        return false
      }
      return true
    }
  }

  private static func escapeUnsafeTTYScalars(_ value: String) -> String {
    var result = ""
    result.reserveCapacity(value.utf8.count)
    for scalar in value.unicodeScalars {
      let code = scalar.value
      if code == 0x09 || code == 0x0A
        || (code >= 0x20
          && code != 0x7F
          && !(0x80...0x9F).contains(code)
          && !(0x202A...0x202E).contains(code)
          && !(0x2066...0x2069).contains(code))
      {
        result.unicodeScalars.append(scalar)
      } else {
        result += "\\u{\(String(code, radix: 16, uppercase: true))}"
      }
    }
    return result
  }

  private static func isSafeComponent(_ value: String) -> Bool {
    !value.isEmpty
      && value != "."
      && value != ".."
      && !value.contains("/")
      && !value.contains("\0")
  }
  #endif
}

struct TatwoGoalRevisionRootAdminEnrollmentContext {
  static let productionDirectoryComponents = [
    "Library",
    "Application Support",
    "Tatwo Ultrawork",
    "GoalRecoveryGrants",
    "v1",
  ]

  let effectiveUID: uid_t
  let sudoUID: uid_t
  let stateDirectoryURL: URL
  let sourceExpectedOwnerUID: uid_t
  let targetRootURL: URL
  let targetDirectoryComponents: [String]
  let targetExpectedOwnerUID: uid_t
  let targetExpectedGroupID: gid_t
  let executableProvenance:
    TatwoGoalRevisionRootAdminExecutableProvenanceV1
  let clock: () -> Date
  let writeReview: (Data) throws -> Void
  let readConfirmation: () throws -> String
}

#if os(macOS)
private final class TatwoGoalRevisionRootAdminTTY {
  private var descriptor: Int32

  private init(descriptor: Int32) {
    self.descriptor = descriptor
  }

  static func openProduction() throws -> TatwoGoalRevisionRootAdminTTY {
    let descriptor = Darwin.open(
      "/dev/tty", O_RDWR | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else {
      throw TatwoGoalRevisionRootAdminEnrollmentError.ttyUnavailable
    }
    var status = stat()
    guard Darwin.fstat(descriptor, &status) == 0,
      (status.st_mode & S_IFMT) == S_IFCHR,
      Darwin.isatty(descriptor) == 1
    else {
      _ = Darwin.close(descriptor)
      throw TatwoGoalRevisionRootAdminEnrollmentError.ttyUnavailable
    }
    return TatwoGoalRevisionRootAdminTTY(descriptor: descriptor)
  }

  func close() {
    guard descriptor >= 0 else { return }
    _ = Darwin.close(descriptor)
    descriptor = -1
  }

  func write(_ data: Data) throws {
    guard descriptor >= 0 else {
      throw TatwoGoalRevisionRootAdminEnrollmentError.ttyUnavailable
    }
    try data.withUnsafeBytes { bytes in
      var offset = 0
      while offset < bytes.count {
        let count = Darwin.write(
          descriptor,
          bytes.baseAddress?.advanced(by: offset),
          bytes.count - offset)
        if count < 0, errno == EINTR { continue }
        guard count > 0 else {
          throw TatwoGoalRevisionRootAdminEnrollmentError.ttyUnavailable
        }
        offset += count
      }
    }
  }

  func readLine() throws -> String {
    guard descriptor >= 0 else {
      throw TatwoGoalRevisionRootAdminEnrollmentError.ttyUnavailable
    }
    var bytes: [UInt8] = []
    bytes.reserveCapacity(32)
    while bytes.count <= 128 {
      var byte: UInt8 = 0
      let count = Darwin.read(descriptor, &byte, 1)
      if count < 0, errno == EINTR { continue }
      guard count == 1 else {
        throw TatwoGoalRevisionRootAdminEnrollmentError.ttyUnavailable
      }
      if byte == 0x0A { break }
      if byte == 0x0D { continue }
      bytes.append(byte)
    }
    guard bytes.count <= 128,
      let value = String(bytes: bytes, encoding: .utf8),
      !value.contains("\0")
    else {
      throw TatwoGoalRevisionRootAdminEnrollmentError
        .confirmationMismatch
    }
    return value
  }
}
#endif
