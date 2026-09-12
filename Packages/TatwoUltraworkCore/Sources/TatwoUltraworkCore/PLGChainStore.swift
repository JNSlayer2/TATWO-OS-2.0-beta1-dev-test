import Foundation

public enum TatwoPLGChainStoreError: Error, Equatable, LocalizedError {
  case missingChain
  case ambiguousChain
  case malformedLine(Int)
  case invalidSeed
  case contextMismatch
  case expectedRunMismatch
  case invalidAnchor(Int)
  case invalidPayload(Int)
  case invalidEnvelope(Int)
  case invalidPreviousHash(Int)
  case invalidRevision(Int)
  case duplicateEventID(UUID)
  case transitionMismatch

  public var errorDescription: String? {
    switch self {
    case .missingChain: "PLG event chain is missing."
    case .ambiguousChain: "Multiple PLG event chains match this goal."
    case .malformedLine(let line): "PLG event chain line \(line) is malformed."
    case .invalidSeed: "PLG event chain seed is invalid."
    case .contextMismatch: "PLG event chain context does not match the projection."
    case .expectedRunMismatch: "PLG event chain head does not match the active run."
    case .invalidAnchor(let line): "PLG host anchor verification failed at line \(line)."
    case .invalidPayload(let line): "PLG event payload hash failed at line \(line)."
    case .invalidEnvelope(let line): "PLG event envelope hash failed at line \(line)."
    case .invalidPreviousHash(let line): "PLG event chain link failed at line \(line)."
    case .invalidRevision(let line): "PLG event revision failed at line \(line)."
    case .duplicateEventID(let id): "PLG event ID \(id) is duplicated."
    case .transitionMismatch: "PLG transition does not match canonical projection."
    }
  }
}

public final class TatwoPLGChainStore: @unchecked Sendable {
  struct HelperRuntimeConfiguration: Equatable {
    let service: String
    let account: String
    let chainDirectoryName: String

    var environmentOverrides: [String: String] {
      [
        "TATWO_ULTRAWORK_PLG_ANCHOR_SERVICE": service,
        "TATWO_ULTRAWORK_PLG_ANCHOR_ACCOUNT": account,
      ]
    }
  }

  private let directory: URL
  private let anchorAuthority: any TatwoPLGAnchorAuthority
  private let lock = NSLock()
  private let encoder: JSONEncoder
  private let decoder = JSONDecoder()

  public init(
    directory: URL,
    anchorAuthority: any TatwoPLGAnchorAuthority
  ) {
    self.directory = directory
    self.anchorAuthority = anchorAuthority
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    self.encoder = encoder
  }

  public static func defaultStore(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    baseDirectory: URL? = nil,
    bundleIdentifier: String? = Bundle.main.bundleIdentifier,
    infoDictionary: [String: Any]? = Bundle.main.infoDictionary
  ) -> TatwoPLGChainStore {
    let base: URL
    if let baseDirectory {
      base = baseDirectory
    } else {
      base = TatwoRuntimeLayout.applicationSupportRoot(environment: environment)
    }
    let anchorConfiguration =
      TatwoPLGKeychainAnchorAuthority.configuration(environment: environment)
    let isProductionBundle =
      bundleIdentifier == "com.tatwo.ultrawork"
    let helperRuntimeConfiguration = helperRuntimeConfiguration(
      bundleIdentifier: bundleIdentifier,
      infoDictionary: infoDictionary,
      environment: environment)
    let helperPath = isProductionBundle
      ? TatwoPLGHelperAnchorAuthority.productionRelativePath
      : environment["TATWO_ULTRAWORK_PLG_ANCHOR_HELPER"]?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let helperURL: URL? = helperPath.flatMap { path in
      guard !path.isEmpty else { return nil }
      return path.hasPrefix("/")
        ? URL(fileURLWithPath: path)
        : Bundle.main.bundleURL.appendingPathComponent(path)
    }
    let expectedHelperSHA256 = isProductionBundle
      ? TatwoPLGHelperAnchorAuthority.productionExecutableSHA256(
        infoDictionary: infoDictionary)
      : environment["TATWO_ULTRAWORK_PLG_ANCHOR_HELPER_SHA256"]?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let chainDirectoryName =
      helperURL == nil
        ? "plg-event-chains"
        : helperRuntimeConfiguration.chainDirectoryName
    let authority: any TatwoPLGAnchorAuthority
    if isProductionBundle && expectedHelperSHA256 == nil {
      authority = TatwoUnavailablePLGAnchorAuthority()
    } else if let helperURL {
      authority = TatwoPLGHelperAnchorAuthority(
        helperURL: helperURL,
        expectedExecutableSHA256: expectedHelperSHA256,
        environmentOverrides:
          helperRuntimeConfiguration.environmentOverrides)
    } else {
      authority = TatwoPLGKeychainAnchorAuthority(
        service: anchorConfiguration.service,
        account: anchorConfiguration.account)
    }
    return TatwoPLGChainStore(
      directory: base.appendingPathComponent(
        chainDirectoryName,
        isDirectory: true),
      anchorAuthority: authority)
  }

  static func helperRuntimeConfiguration(
    bundleIdentifier: String?,
    infoDictionary: [String: Any]?,
    environment: [String: String]
  ) -> HelperRuntimeConfiguration {
    let buildClass = (infoDictionary?["TatwoBuildClass"] as? String)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    let distributionReady: Bool = {
      if let value = infoDictionary?["TatwoDistributionReady"] as? Bool {
        return value
      }
      if let value = infoDictionary?["TatwoDistributionReady"] as? NSNumber {
        return value.boolValue
      }
      return false
    }()
    if bundleIdentifier == "com.tatwo.ultrawork",
       buildClass == "local-internal",
       !distributionReady
    {
      return HelperRuntimeConfiguration(
        service:
          "ai.tatwo.ultrawork.plg-chain-anchor.local-internal.v1",
        account: "stable-helper-v1",
        chainDirectoryName: "plg-event-chains-local-internal-v1")
    }

    let service = environment["TATWO_ULTRAWORK_PLG_ANCHOR_SERVICE"]?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let account = environment["TATWO_ULTRAWORK_PLG_ANCHOR_ACCOUNT"]?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return HelperRuntimeConfiguration(
      service:
        service.flatMap { $0.isEmpty ? nil : $0 }
          ?? "ai.tatwo.ultrawork.plg-chain-anchor.production.v3",
      account:
        account.flatMap { $0.isEmpty ? nil : $0 }
          ?? "stable-helper-v1",
      chainDirectoryName: "plg-event-chains-v3")
  }

  public func storageURL(
    contractID: String,
    goalID: String,
    runID: UUID
  ) -> URL {
    let digest = TatwoArtifactReviewHasher.sha256(
      "\(contractID)|\(goalID)|\(runID.uuidString.lowercased())")
    return directory.appendingPathComponent("\(digest).jsonl")
  }

  public func begin(run: TatwoPLGRun) throws {
    lock.lock()
    defer { lock.unlock() }

    let url = storageURL(
      contractID: run.contractID,
      goalID: run.goalID,
      runID: run.id)
    try TatwoFileLock.withExclusiveLock(for: discoveryLockURL) {
      try TatwoFileLock.withExclusiveLock(for: url) {
        if FileManager.default.fileExists(atPath: url.path) {
          let replay = try replayUnlocked(
            contractID: run.contractID,
            goalID: run.goalID,
            runID: run.id)
          guard replay.run == run else {
            throw TatwoPLGChainStoreError.expectedRunMismatch
          }
          return
        }
        guard isNonAuthoritativeSeed(run) else {
          throw TatwoPLGChainStoreError.invalidSeed
        }

        let seedHash = try hash(run)
        let anchorMaterial = anchorMaterial(
          kind: "seed",
          contractID: run.contractID,
          goalID: run.goalID,
          runID: run.id,
          revision: run.revision,
          headHash: seedHash)
        let record = TatwoPLGChainSeedRecord(
          contractID: run.contractID,
          goalID: run.goalID,
          runID: run.id,
          run: run,
          seedHash: seedHash,
          anchorMAC: try anchorAuthority.sign(anchorMaterial))
        let line = try encodedLine(.seed(record))
        try FileManager.default.createDirectory(
          at: directory,
          withIntermediateDirectories: true)
        try line.write(to: url, options: .withoutOverwriting)
      }
    }
  }

  public func append(
    transition: TatwoPLGTransition,
    from expectedRun: TatwoPLGRun
  ) throws -> TatwoPLGReplayResult {
    lock.lock()
    defer { lock.unlock() }

    let url = storageURL(
      contractID: expectedRun.contractID,
      goalID: expectedRun.goalID,
      runID: expectedRun.id)
    return try TatwoFileLock.withExclusiveLock(for: url) {
      let current = try replayUnlocked(
        contractID: expectedRun.contractID,
        goalID: expectedRun.goalID,
        runID: expectedRun.id)
      guard current.run == expectedRun else {
        throw TatwoPLGChainStoreError.expectedRunMismatch
      }
      let canonical = try TatwoPLGOrchestrator.project(
        transition.event,
        onto: current.run)
      guard canonical == transition.run else {
        throw TatwoPLGChainStoreError.transitionMismatch
      }

      let event = transition.event
      let payloadHash = try hash(event)
      let unsignedMaterial = envelopeMaterial(
        contractID: expectedRun.contractID,
        goalID: expectedRun.goalID,
        runID: expectedRun.id,
        revision: event.atRevision,
        eventID: event.eventID,
        previousHash: current.headHash,
        payloadHash: payloadHash)
      let envelopeHash = TatwoArtifactReviewHasher.sha256(unsignedMaterial)
      let anchor = try anchorAuthority.sign(
        anchorMaterial(
          kind: "event",
          contractID: expectedRun.contractID,
          goalID: expectedRun.goalID,
          runID: expectedRun.id,
          revision: event.atRevision,
          headHash: envelopeHash))
      let envelope = TatwoPLGEventEnvelope(
        contractID: expectedRun.contractID,
        goalID: expectedRun.goalID,
        runID: expectedRun.id,
        revision: event.atRevision,
        eventID: event.eventID,
        previousHash: current.headHash,
        payloadHash: payloadHash,
        event: event,
        envelopeHash: envelopeHash,
        anchorMAC: anchor)
      let eventAnchorMaterial = anchorMaterial(
        kind: "event",
        contractID: expectedRun.contractID,
        goalID: expectedRun.goalID,
        runID: expectedRun.id,
        revision: event.atRevision,
        headHash: envelopeHash)
      guard try anchorAuthority.verify(
        envelope.anchorMAC,
        material: eventAnchorMaterial)
      else {
        throw TatwoPLGChainStoreError.invalidAnchor(
          current.appliedEventIDs.count + 2)
      }
      let line = try encodedLine(.event(envelope))
      let handle = try FileHandle(forWritingTo: url)
      defer { try? handle.close() }
      try handle.seekToEnd()
      try handle.write(contentsOf: line)

      var eventIDs = current.appliedEventIDs
      guard eventIDs.insert(event.eventID).inserted else {
        throw TatwoPLGChainStoreError.duplicateEventID(event.eventID)
      }
      var run = transition.run
      run.markVerifiedReplay(headHash: envelopeHash)
      return TatwoPLGReplayResult(
        run: run,
        appliedEventIDs: eventIDs,
        headHash: envelopeHash)
    }
  }

  public func replay(
    contractID: String,
    goalID: String,
    runID: UUID
  ) throws -> TatwoPLGReplayResult {
    lock.lock()
    defer { lock.unlock() }
    let url = storageURL(
      contractID: contractID,
      goalID: goalID,
      runID: runID)
    return try TatwoFileLock.withExclusiveLock(for: url) {
      try replayUnlocked(
        contractID: contractID,
        goalID: goalID,
        runID: runID)
    }
  }

  public func replayUnique(
    contractID: String,
    goalID: String,
    preferredRunID: UUID? = nil
  ) throws -> TatwoPLGReplayResult {
    lock.lock()
    defer { lock.unlock() }
    return try TatwoFileLock.withExclusiveLock(for: discoveryLockURL) {
      var runIDs = try discoverRunIDsUnlocked(
        contractID: contractID,
        goalID: goalID)
      if let preferredRunID {
        let preferredURL = storageURL(
          contractID: contractID,
          goalID: goalID,
          runID: preferredRunID)
        if FileManager.default.fileExists(atPath: preferredURL.path),
           !runIDs.contains(preferredRunID)
        {
          runIDs.append(preferredRunID)
        }
      }
      guard !runIDs.isEmpty else {
        throw TatwoPLGChainStoreError.missingChain
      }
      guard runIDs.count == 1, let runID = runIDs.first else {
        throw TatwoPLGChainStoreError.ambiguousChain
      }
      let url = storageURL(
        contractID: contractID,
        goalID: goalID,
        runID: runID)
      return try TatwoFileLock.withExclusiveLock(for: url) {
        try replayUnlocked(
          contractID: contractID,
          goalID: goalID,
          runID: runID)
      }
    }
  }

  private func replayUnlocked(
    contractID: String,
    goalID: String,
    runID: UUID
  ) throws -> TatwoPLGReplayResult {
    let url = storageURL(
      contractID: contractID,
      goalID: goalID,
      runID: runID)
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw TatwoPLGChainStoreError.missingChain
    }
    let data = try Data(contentsOf: url)
    let lines = try physicalLines(data)
    guard !lines.isEmpty else {
      throw TatwoPLGChainStoreError.missingChain
    }
    let first = try decodeLine(lines[0], line: 1)
    guard first.kind == .seed,
          let seed = first.seed,
          first.event == nil,
          seed.contractID == contractID,
          seed.goalID == goalID,
          seed.runID == runID,
          seed.run.contractID == contractID,
          seed.run.goalID == goalID,
          seed.run.id == runID,
          isNonAuthoritativeSeed(seed.run),
          seed.seedHash == (try hash(seed.run))
    else {
      throw TatwoPLGChainStoreError.invalidSeed
    }
    let seedAnchor = anchorMaterial(
      kind: "seed",
      contractID: contractID,
      goalID: goalID,
      runID: runID,
      revision: seed.run.revision,
      headHash: seed.seedHash)
    guard try anchorAuthority.verify(
      seed.anchorMAC,
      material: seedAnchor)
    else {
      throw TatwoPLGChainStoreError.invalidAnchor(1)
    }

    var run = seed.run
    var headHash = seed.seedHash
    var eventIDs = Set<UUID>()
    for offset in 1..<lines.count {
      let lineNumber = offset + 1
      let line = try decodeLine(lines[offset], line: lineNumber)
      guard line.kind == .event,
            line.seed == nil,
            let envelope = line.event,
            envelope.contractID == contractID,
            envelope.goalID == goalID,
            envelope.runID == runID
      else {
        throw TatwoPLGChainStoreError.contextMismatch
      }
      guard envelope.previousHash == headHash else {
        throw TatwoPLGChainStoreError.invalidPreviousHash(lineNumber)
      }
      guard envelope.revision == run.revision + 1,
            envelope.event.atRevision == envelope.revision
      else {
        throw TatwoPLGChainStoreError.invalidRevision(lineNumber)
      }
      guard envelope.eventID == envelope.event.eventID else {
        throw TatwoPLGChainStoreError.invalidPayload(lineNumber)
      }
      guard eventIDs.insert(envelope.eventID).inserted else {
        throw TatwoPLGChainStoreError.duplicateEventID(envelope.eventID)
      }
      guard envelope.payloadHash == (try hash(envelope.event)) else {
        throw TatwoPLGChainStoreError.invalidPayload(lineNumber)
      }
      let material = envelopeMaterial(
        contractID: contractID,
        goalID: goalID,
        runID: runID,
        revision: envelope.revision,
        eventID: envelope.eventID,
        previousHash: envelope.previousHash,
        payloadHash: envelope.payloadHash)
      guard envelope.envelopeHash
        == TatwoArtifactReviewHasher.sha256(material)
      else {
        throw TatwoPLGChainStoreError.invalidEnvelope(lineNumber)
      }
      let anchor = anchorMaterial(
        kind: "event",
        contractID: contractID,
        goalID: goalID,
        runID: runID,
        revision: envelope.revision,
        headHash: envelope.envelopeHash)
      guard try anchorAuthority.verify(
        envelope.anchorMAC,
        material: anchor)
      else {
        throw TatwoPLGChainStoreError.invalidAnchor(lineNumber)
      }
      run = try TatwoPLGOrchestrator.project(envelope.event, onto: run)
      headHash = envelope.envelopeHash
    }
    run.markVerifiedReplay(headHash: headHash)
    return TatwoPLGReplayResult(
      run: run,
      appliedEventIDs: eventIDs,
      headHash: headHash)
  }

  private func encodedLine(_ line: TatwoPLGChainLine) throws -> Data {
    var data = try encoder.encode(line)
    data.append(0x0A)
    return data
  }

  private var discoveryLockURL: URL {
    directory.appendingPathComponent(".chain-discovery")
  }

  private func discoverRunIDsUnlocked(
    contractID: String,
    goalID: String
  ) throws -> [UUID] {
    guard FileManager.default.fileExists(atPath: directory.path) else {
      return []
    }
    let urls = try FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles])
      .filter { $0.pathExtension == "jsonl" }
    return urls.compactMap { url -> UUID? in
      guard let data = try? Data(contentsOf: url) else {
        return nil
      }
      let first: Data
      if let newline = data.firstIndex(of: 0x0A) {
        first = Data(data[..<newline])
      } else {
        first = data
      }
      guard !first.isEmpty,
            let line = try? decoder.decode(
              TatwoPLGChainLine.self,
              from: first),
            line.kind == .seed,
            let seed = line.seed,
            seed.contractID == contractID,
            seed.goalID == goalID
      else {
        return nil
      }
      return seed.runID
    }
  }

  private func physicalLines(_ data: Data) throws -> [Data] {
    let bytes = [UInt8](data)
    var lines: [Data] = bytes
      .split(separator: 0x0A, omittingEmptySubsequences: false)
      .map { Data($0) }
    if lines.last?.isEmpty == true {
      lines.removeLast()
    }
    guard !lines.isEmpty else {
      throw TatwoPLGChainStoreError.missingChain
    }
    if let index = lines.firstIndex(where: { $0.isEmpty }) {
      throw TatwoPLGChainStoreError.malformedLine(index + 1)
    }
    return lines
  }

  private func decodeLine(
    _ data: Data,
    line: Int
  ) throws -> TatwoPLGChainLine {
    do {
      return try decoder.decode(TatwoPLGChainLine.self, from: data)
    } catch {
      throw TatwoPLGChainStoreError.malformedLine(line)
    }
  }

  private func hash<T: Encodable>(_ value: T) throws -> String {
    TatwoArtifactReviewHasher.sha256(try encoder.encode(value))
  }

  private func isNonAuthoritativeSeed(_ run: TatwoPLGRun) -> Bool {
    !run.branchGoals.contains {
      $0.status == .passed
        || $0.reportedToMainline
        || $0.domainReceipt != nil
        || $0.authorityRevision != nil
        || $0.authoritySeal != nil
    }
  }

  private func envelopeMaterial(
    contractID: String,
    goalID: String,
    runID: UUID,
    revision: Int,
    eventID: UUID,
    previousHash: String,
    payloadHash: String
  ) -> String {
    [
      "TatwoPLGEventEnvelopeV1",
      contractID,
      goalID,
      runID.uuidString.lowercased(),
      String(revision),
      eventID.uuidString.lowercased(),
      previousHash,
      payloadHash,
    ].joined(separator: "|")
  }

  private func anchorMaterial(
    kind: String,
    contractID: String,
    goalID: String,
    runID: UUID,
    revision: Int,
    headHash: String
  ) -> String {
    [
      "TatwoPLGHostAnchorV1",
      kind,
      contractID,
      goalID,
      runID.uuidString.lowercased(),
      String(revision),
      headHash,
    ].joined(separator: "|")
  }
}

private struct TatwoUnavailablePLGAnchorAuthority: TatwoPLGAnchorAuthority {
  func sign(_ material: String) throws -> String {
    throw TatwoPLGAnchorError.unavailable
  }

  func verify(_ signature: String, material: String) throws -> Bool {
    throw TatwoPLGAnchorError.unavailable
  }
}
