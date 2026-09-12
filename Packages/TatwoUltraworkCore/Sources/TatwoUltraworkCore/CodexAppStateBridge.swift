import Foundation

public struct TatwoCodexAppStateBridge: Sendable {
  public struct WorkspaceRootSyncReceipt: Sendable, Equatable {
    public var path: String
    public var globalStateURL: URL
    public var backupURL: URL?
    public var changedKeys: [String]

    public var didChange: Bool { !changedKeys.isEmpty }
  }

  public struct SourcePaths: Sendable, Equatable {
    public var stateDatabaseURL: URL
    public var globalStateURL: URL

    public init(stateDatabaseURL: URL, globalStateURL: URL) {
      self.stateDatabaseURL = stateDatabaseURL
      self.globalStateURL = globalStateURL
    }

    /// This intentionally avoids APIs that resolve or stat symlink destinations.
    /// It checks lexical paths and reads only symlink target strings so the gate
    /// itself does not probe a removable volume before explicit opt in.
    public var requiresExternalVolumeOptIn: Bool {
      Self.isExternalVolumePath(stateDatabaseURL)
        || Self.isExternalVolumePath(globalStateURL)
    }

    private static func isExternalVolumePath(_ url: URL) -> Bool {
      var visitedPaths: Set<String> = []
      return isExternalVolumePath(
        url.standardizedFileURL.path,
        visitedPaths: &visitedPaths,
        remainingSymlinkHops: 32)
    }

    private static func isExternalVolumePath(
      _ path: String,
      visitedPaths: inout Set<String>,
      remainingSymlinkHops: Int
    ) -> Bool {
      let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
      if ExternalVolumeReader.isExternalVolumePath(standardizedPath) {
        return true
      }
      guard remainingSymlinkHops > 0,
            visitedPaths.insert(standardizedPath).inserted
      else {
        return false
      }

      let components = standardizedPath.split(separator: "/", omittingEmptySubsequences: true)
      var candidatePath = ""

      for (index, component) in components.enumerated() {
        candidatePath += "/\(component)"
        guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: candidatePath) else {
          continue
        }

        let destinationURL: URL
        if destination.hasPrefix("/") {
          destinationURL = URL(fileURLWithPath: destination)
        } else {
          destinationURL = URL(fileURLWithPath: candidatePath)
            .deletingLastPathComponent()
            .appendingPathComponent(destination)
        }

        let redirectedURL = components.dropFirst(index + 1).reduce(destinationURL) {
          $0.appendingPathComponent(String($1))
        }
        return isExternalVolumePath(
          redirectedURL.standardizedFileURL.path,
          visitedPaths: &visitedPaths,
          remainingSymlinkHops: remainingSymlinkHops - 1)
      }

      return false
    }
  }

  public enum MirrorStatus: String, Sendable, Equatable {
    case loaded
    case notEnabled
    case unavailable
  }

  public struct MirrorLoadResult: Sendable, Equatable {
    public var document: TatwoNativeChatStoreDocument?
    public var status: MirrorStatus
    public var failure: ExternalVolumeFailure?
    public var lastGoodAt: Date?
    public var isStale: Bool

    public init(
      document: TatwoNativeChatStoreDocument?,
      status: MirrorStatus,
      failure: ExternalVolumeFailure? = nil,
      lastGoodAt: Date? = nil,
      isStale: Bool = false
    ) {
      self.document = document
      self.status = status
      self.failure = failure
      self.lastGoodAt = lastGoodAt
      self.isStale = isStale
    }
  }

  public enum BridgeError: Error, Equatable {
    case unsupportedPlatform
    case mainThreadSubprocessDenied
    case sqliteCommandFailed(String)
    case invalidWorkspaceRoot(String)
    case invalidGlobalStateJSON(String)
    case transcriptNotFound(String)
  }

  public var sourcePaths: SourcePaths
  public var maxThreadRows: Int
  public var maxThreadsPerProject: Int
  public var maxStandaloneThreads: Int

  public init(
    sourcePaths: SourcePaths = .defaultPaths(),
    maxThreadRows: Int = 160,
    maxThreadsPerProject: Int = 12,
    maxStandaloneThreads: Int = 10
  ) {
    self.sourcePaths = sourcePaths
    self.maxThreadRows = maxThreadRows
    self.maxThreadsPerProject = maxThreadsPerProject
    self.maxStandaloneThreads = maxStandaloneThreads
  }

  public func loadDocumentOverlay() throws -> TatwoNativeChatStoreDocument {
    let globalState = CodexGlobalState.load(from: sourcePaths.globalStateURL)
    let rows = try loadThreadRows()
      .filter { !$0.isArchived }
      .filter(Self.isVisibleSidebarRow)

    var projectBuckets: [String: [TatwoNativeChatThread]] = [:]
    var standalone: [TatwoNativeChatThread] = []
    let projectless = Set(globalState.projectlessThreadIDs)
    let savedProjectPaths = globalState.savedProjectPathSet()

    for row in rows {
      let thread = row.toTatwoThread()
      let assignment = globalState.threadProjectAssignments[row.id]
      let assignedPath = assignment?.path ?? assignment?.projectID
      let hintPath = globalState.threadWorkspaceRootHints[row.id]
      let candidateProject = Self.normalizePath(assignedPath) ?? Self.normalizePath(hintPath)
      let rowCWD = Self.normalizePath(row.cwd)
      let visibleProjectPath = [candidateProject, rowCWD]
        .compactMap { $0 }
        .first { savedProjectPaths.isEmpty || savedProjectPaths.contains($0) }
      let isTatwoOwnedChatWorkspace = Self.isTatwoOwnedChatWorkspace(rowCWD)
      let isProjectless = projectless.contains(row.id)
        || (candidateProject == nil && rowCWD == nil)
        || (candidateProject == nil && isTatwoOwnedChatWorkspace)
        || row.threadSource.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "user"
          && projectless.contains(row.id)

      if !isProjectless, let projectPath = visibleProjectPath, !projectPath.isEmpty {
        projectBuckets[projectPath, default: []].append(thread)
      } else if isProjectless {
        standalone.append(thread)
      }
    }

    let orderedProjectPaths = orderedProjects(globalState: globalState, buckets: projectBuckets)
    let projects = orderedProjectPaths.compactMap { path -> TatwoNativeChatProject? in
      let sortedThreads = orderedThreads(
        projectPath: path,
        threads: projectBuckets[path] ?? [],
        globalState: globalState
      )
      guard !sortedThreads.isEmpty || globalState.projectOrder.contains(path) || globalState.electronSavedWorkspaceRoots.contains(path) else { return nil }
      return TatwoNativeChatProject(
        id: Self.stableProjectUUID(for: path),
        name: Self.projectDisplayName(for: path),
        workdir: path,
        isExpanded: true,
        threads: Array(sortedThreads.prefix(maxThreadsPerProject))
      )
    }

    let orderedStandalone = standalone
      .sorted { $0.updatedAt > $1.updatedAt }
      .prefix(maxStandaloneThreads)

    return TatwoNativeChatStoreDocument(
      threads: Array(orderedStandalone),
      projects: projects
    )
  }

  /// Loads the optional Codex mirror without allowing mirror failures to block
  /// Tatwo-owned chat state. External-volume sources are skipped before any
  /// filesystem probe unless the user has explicitly opted in.
  public func loadDocumentOverlayFailSoft(
    externalVolumeOptIn: Bool,
    cacheRootURL: URL? = defaultMirrorCacheRoot()
  ) -> MirrorLoadResult {
    let requiresExternalVolumeOptIn = sourcePaths.requiresExternalVolumeOptIn
    if requiresExternalVolumeOptIn, !externalVolumeOptIn {
      return MirrorLoadResult(document: nil, status: .notEnabled)
    }

    let sourceProbe: (isRegularFile: Bool, failure: ExternalVolumeFailure?)
    if requiresExternalVolumeOptIn {
      let outcome = ExternalVolumeReader(rootURL: sourcePaths.stateDatabaseURL)
        .inspectSync()
      sourceProbe = (
        outcome.value?.isRegularFile == true,
        outcome.failure)
    } else {
      do {
        let values = try sourcePaths.stateDatabaseURL.resourceValues(
          forKeys: [.isRegularFileKey])
        let isRegularFile = values.isRegularFile == true
        sourceProbe = (
          isRegularFile,
          isRegularFile ? nil : .volumeAbsent)
      } catch {
        sourceProbe = (
          false,
          ExternalVolumeReader.classify(error).failure)
      }
    }

    return Self.loadDocumentOverlayFailSoft(
      sourcePaths: sourcePaths,
      externalVolumeOptIn: externalVolumeOptIn,
      sourceAccessCheck: {
        sourceProbe.isRegularFile
      },
      sourceFailure: { sourceProbe.failure },
      cacheRootURL: cacheRootURL
    ) {
      try loadDocumentOverlay()
    }
  }

  static func loadDocumentOverlayFailSoft(
    sourcePaths: SourcePaths,
    externalVolumeOptIn: Bool,
    sourceAccessCheck: () -> Bool = { true },
    sourceFailure: () -> ExternalVolumeFailure? = { nil },
    cacheRootURL: URL? = defaultMirrorCacheRoot(),
    loader: () throws -> TatwoNativeChatStoreDocument
  ) -> MirrorLoadResult {
    if sourcePaths.requiresExternalVolumeOptIn, !externalVolumeOptIn {
      return MirrorLoadResult(document: nil, status: .notEnabled)
    }
    if !sourceAccessCheck() {
      return MirrorLoadResult(
        document: nil,
        status: .unavailable,
        failure: sourceFailure() ?? .volumeAbsent)
    }
    do {
      let document = try loader()
      let lastGoodAt = Date()
      writeMirrorCache(
        document,
        sourceKey: mirrorSourceKey(sourcePaths),
        lastGoodAt: lastGoodAt,
        cacheRootURL: cacheRootURL)
      return MirrorLoadResult(
        document: document,
        status: .loaded,
        lastGoodAt: lastGoodAt)
    } catch {
      let classification = ExternalVolumeReader.classify(error)
      if let cached = readMirrorCache(
        sourceKey: mirrorSourceKey(sourcePaths),
        cacheRootURL: cacheRootURL
      ) {
        return MirrorLoadResult(
          document: cached.document,
          status: .loaded,
          failure: classification.failure,
          lastGoodAt: cached.lastGoodAt,
          isStale: true)
      }
      return MirrorLoadResult(
        document: nil,
        status: .unavailable,
        failure: classification.failure)
    }
  }

  public static func defaultMirrorCacheRoot(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> URL {
    TatwoRuntimeLayout.applicationSupportRoot(environment: environment)
      .appendingPathComponent("ExternalVolumeCache", isDirectory: true)
  }

  private struct MirrorCache: Codable {
    let schema: String
    let lastGoodAt: Date
    let document: TatwoNativeChatStoreDocument
  }

  private static func mirrorSourceKey(_ sourcePaths: SourcePaths) -> String {
    let identity = sourcePaths.stateDatabaseURL.standardizedFileURL.path
      + "|" + sourcePaths.globalStateURL.standardizedFileURL.path
    return ExternalVolumeReader.sourceKey(
      for: URL(fileURLWithPath: identity),
      logicalResource: "codex-app-mirror")
  }

  private static func mirrorCacheURL(
    sourceKey: String,
    cacheRootURL: URL?
  ) -> URL? {
    guard let cacheRootURL else { return nil }
    return cacheRootURL.appendingPathComponent(
      "\(sourceKey)-codex-mirror.json",
      isDirectory: false)
  }

  private static func writeMirrorCache(
    _ document: TatwoNativeChatStoreDocument,
    sourceKey: String,
    lastGoodAt: Date,
    cacheRootURL: URL?
  ) {
    guard let url = mirrorCacheURL(sourceKey: sourceKey, cacheRootURL: cacheRootURL),
      let data = try? JSONEncoder().encode(
        MirrorCache(
          schema: "TatwoExternalVolumeMirrorCacheV1",
          lastGoodAt: lastGoodAt,
          document: document
        )
      )
    else { return }
    do {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true)
      try data.write(to: url, options: [.atomic])
    } catch {
      // Cache is advisory and must never make a fresh mirror load fail.
    }
  }

  private static func readMirrorCache(
    sourceKey: String,
    cacheRootURL: URL?
  ) -> MirrorCache? {
    guard let url = mirrorCacheURL(sourceKey: sourceKey, cacheRootURL: cacheRootURL),
      let data = try? Data(contentsOf: url),
      let cache = try? JSONDecoder().decode(MirrorCache.self, from: data),
      cache.schema == "TatwoExternalVolumeMirrorCacheV1"
    else { return nil }
    return cache
  }

  public func loadTranscript(threadID: String, maxMessages: Int = 80) throws -> [TatwoNativeChatStoredMessage] {
    guard let rolloutPath = try rolloutPath(for: threadID) else {
      throw BridgeError.transcriptNotFound(threadID)
    }
    return try Self.loadTranscript(
      from: URL(fileURLWithPath: rolloutPath),
      maxMessages: maxMessages)
  }

  public func mergeOverlay(into base: TatwoNativeChatStoreDocument) throws -> TatwoNativeChatStoreDocument {
    let overlay = try loadDocumentOverlay()
    return Self.merge(base: base, overlay: overlay)
  }

  /// One-shot, minimal Codex App project-root sync for Tatwo-created projects.
  ///
  /// This intentionally only updates Codex App's workspace-root lists in
  /// `.codex-global-state.json`. It does not create/patch Codex threads,
  /// sessions, sqlite rows, auth state, or any Codex App bundle files. The goal
  /// is to let a folder project created from OS Chat appear as a normal Codex
  /// App workspace root so the human can continue there without the two apps
  /// diverging on project identity.
  public func registerWorkspaceRoot(_ rawPath: String) throws -> WorkspaceRootSyncReceipt {
    guard let normalizedPath = Self.normalizePath(rawPath),
          FileManager.default.fileExists(atPath: normalizedPath)
    else {
      throw BridgeError.invalidWorkspaceRoot(rawPath)
    }

    var object: [String: Any]
    var originalData: Data?
    let globalStateProbe = ExternalVolumeReader(rootURL: sourcePaths.globalStateURL)
      .readBoundedFileSync(sourcePaths.globalStateURL, maximumBytes: 2 * 1_024 * 1_024)
    if let data = globalStateProbe.value {
      originalData = data
      let decoded = try JSONSerialization.jsonObject(with: data, options: [])
      guard let dictionary = decoded as? [String: Any] else {
        throw BridgeError.invalidGlobalStateJSON("root object is not a dictionary")
      }
      object = dictionary
    } else {
      object = [:]
    }

    let keys = ["project-order", "electron-saved-workspace-roots"]
    var changedKeys: [String] = []
    for key in keys {
      var roots = object[key] as? [String] ?? []
      let hasRoot = roots.contains { Self.sameProject(lhs: $0, rhs: normalizedPath) }
      guard !hasRoot else { continue }
      roots.append(normalizedPath)
      object[key] = roots
      changedKeys.append(key)
    }

    guard !changedKeys.isEmpty else {
      return WorkspaceRootSyncReceipt(
        path: normalizedPath,
        globalStateURL: sourcePaths.globalStateURL,
        backupURL: nil,
        changedKeys: [])
    }

    let backupURL: URL?
    if let originalData {
      let formatter = ISO8601DateFormatter()
      formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      let safeTimestamp = formatter.string(from: Date())
        .replacingOccurrences(of: ":", with: "-")
      let candidate = sourcePaths.globalStateURL
        .deletingLastPathComponent()
        .appendingPathComponent(".codex-global-state.json.tatwo-backup-\(safeTimestamp)")
      try originalData.write(to: candidate, options: [.atomic])
      backupURL = candidate
    } else {
      try FileManager.default.createDirectory(
        at: sourcePaths.globalStateURL.deletingLastPathComponent(),
        withIntermediateDirectories: true)
      backupURL = nil
    }

    let newData = try JSONSerialization.data(
      withJSONObject: object,
      options: [.prettyPrinted, .sortedKeys])
    try newData.write(to: sourcePaths.globalStateURL, options: [.atomic])

    return WorkspaceRootSyncReceipt(
      path: normalizedPath,
      globalStateURL: sourcePaths.globalStateURL,
      backupURL: backupURL,
      changedKeys: changedKeys)
  }

  public static func merge(base: TatwoNativeChatStoreDocument, overlay: TatwoNativeChatStoreDocument) -> TatwoNativeChatStoreDocument {
    var result = base
    var seenThreadIDs = Set<UUID>()
    var seenCodexSessionIDs = Set<String>()

    func remember(_ thread: TatwoNativeChatThread) {
      seenThreadIDs.insert(thread.id)
      if let codexID = normalizedString(thread.codexSessionID) {
        seenCodexSessionIDs.insert(codexID)
      }
    }

    result.threads.forEach(remember)
    result.projects.flatMap(\.threads).forEach(remember)

    for overlayThread in overlay.threads {
      let codexID = normalizedString(overlayThread.codexSessionID)
      guard !seenThreadIDs.contains(overlayThread.id), codexID.map({ !seenCodexSessionIDs.contains($0) }) ?? true else { continue }
      result.threads.append(overlayThread)
      remember(overlayThread)
    }
    result.threads.sort { $0.updatedAt > $1.updatedAt }

    for overlayProject in overlay.projects {
      if let existingIndex = result.projects.firstIndex(where: { sameProject(lhs: $0.workdir, rhs: overlayProject.workdir) }) {
        result.projects[existingIndex].isExpanded = result.projects[existingIndex].isExpanded || overlayProject.isExpanded
        if result.projects[existingIndex].name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          result.projects[existingIndex].name = overlayProject.name
        }
        // Matching workdir is not a license to import Codex sessions as
        // new project children. Explicit 新增/匯入 owns project membership.
      } else {
        // Codex session restore must not auto-create Tatwo projects.
      }
    }

    result.updatedAt = Date()
    return result
  }

  /// Restores Tatwo-owned interaction state onto rows refreshed from the
  /// Codex mirror. Codex remains authoritative for title, preview, and
  /// archive state of matching rows; Tatwo remains authoritative for
  /// project membership, Plan mode, Goal/PLG state, child sessions,
  /// provider handles, and saved transcript.
  public static func restoringLocalInteractionState(
    local: TatwoNativeChatStoreDocument,
    in mirrored: TatwoNativeChatStoreDocument
  ) -> TatwoNativeChatStoreDocument {
    let localThreads = local.threads + local.projects.flatMap(\.threads)
    let localByID = Dictionary(
      localThreads.map { ($0.id, $0) },
      uniquingKeysWith: { lhs, rhs in lhs.updatedAt >= rhs.updatedAt ? lhs : rhs })
    let localByCodexSessionID = Dictionary(
      localThreads.compactMap { thread in
        normalizedString(thread.codexSessionID).map { ($0, thread) }
      },
      uniquingKeysWith: { lhs, rhs in lhs.updatedAt >= rhs.updatedAt ? lhs : rhs })

    func restored(_ mirror: TatwoNativeChatThread) -> TatwoNativeChatThread {
      let localThread = localByID[mirror.id]
        ?? normalizedString(mirror.codexSessionID).flatMap { localByCodexSessionID[$0] }
      guard let localThread else { return mirror }

      var result = mirror
      result.id = localThread.id
      result.cliSessionID = localThread.cliSessionID ?? mirror.cliSessionID
      result.codexSessionID = mirror.codexSessionID ?? localThread.codexSessionID
      result.codexCLISessionID = localThread.codexCLISessionID ?? mirror.codexCLISessionID
      result.claudeSessionID = localThread.claudeSessionID ?? mirror.claudeSessionID
      if !localThread.adapterSessionHandles.isEmpty {
        result.adapterSessionHandles = localThread.adapterSessionHandles
      }
      result.updatedAt = max(localThread.updatedAt, mirror.updatedAt)
      result.isPinned = localThread.isPinned
      result.isPlanModeEnabled = localThread.isPlanModeEnabled
      result.loopsConfig = localThread.loopsConfig
      result.workOSGoalID = localThread.workOSGoalID
      result.workOSContractID = localThread.workOSContractID
      result.selectedThreadWorkOSContext = localThread.selectedThreadWorkOSContext
      result.threadPluginIDs = localThread.threadPluginIDs
      result.discussions = localThread.discussions
      result.activePLGRunProjection = localThread.activePLGRunProjection
      result.loopsSessions = localThread.loopsSessions
      if localThread.messages != nil {
        result.messages = localThread.messages
      }
      return result
    }

    var result = mirrored
    result.threads = mirrored.threads.map(restored)
    result.projects = mirrored.projects.map { project in
      var copy = project
      copy.threads = project.threads.map(restored)
      return copy
    }
    return result
  }

  /// Builds the local side of the Codex sidebar merge without reviving stale
  /// rows that were previously imported from Codex App.
  ///
  /// A Tatwo-created thread keeps its own UUID even after a CLI/provider
  /// session id is captured. Codex-mirror rows instead use the Codex session
  /// id as the thread UUID. That distinction lets a newly completed Tatwo
  /// session survive app relaunch while Codex state.sqlite is still catching
  /// up, without re-adding old mirror-only rows that disappeared from Codex.
  public static func localOverlayDocument(
    local: TatwoNativeChatStoreDocument,
    mirror: TatwoNativeChatStoreDocument
  ) -> TatwoNativeChatStoreDocument {
    let mirrorThreads = mirror.threads + mirror.projects.flatMap(\.threads)
    let mirroredCodexSessionIDs = Set(mirrorThreads.compactMap {
      normalizedString($0.codexSessionID)
    })

    func shouldKeep(_ thread: TatwoNativeChatThread) -> Bool {
      guard !thread.isArchived else { return false }
      let title = thread.title.trimmingCharacters(in: .whitespacesAndNewlines)
      let preview = thread.lastPreview.trimmingCharacters(in: .whitespacesAndNewlines)
      let hasMessage = thread.messages?.contains { message in
        let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !text.isEmpty && !looksLikeInternalDelegationPrompt(text)
      } == true
      let combined = [title, preview].filter { !$0.isEmpty }.joined(separator: "\n")
      guard !looksLikeInternalDelegationPrompt(combined) else { return false }

      let lowerTitle = title.lowercased()
      let isDefaultEmptyChat = title.isEmpty || title == "新聊天" || lowerTitle == "new chat"
      guard !preview.isEmpty || hasMessage || !isDefaultEmptyChat else { return false }

      guard let codexID = normalizedString(thread.codexSessionID) else {
        return true
      }
      guard !mirroredCodexSessionIDs.contains(codexID) else {
        return false
      }
      return thread.id.uuidString.lowercased() != codexID.lowercased()
    }

    let standalone = local.threads.filter(shouldKeep)
    let projects = local.projects.compactMap { project -> TatwoNativeChatProject? in
      var copy = project
      copy.threads = project.threads.filter(shouldKeep)
      return copy.threads.isEmpty ? nil : copy
    }
    return TatwoNativeChatStoreDocument(
      updatedAt: local.updatedAt,
      threads: standalone,
      projects: projects)
  }

  static func sanitizedTranscriptTextForMirrorTesting(
    _ rawText: String,
    normalizedRole: String
  ) -> String? {
    cleanedTranscriptText(
      rawText,
      normalizedRole: normalizedRole)
  }
}

public extension TatwoCodexAppStateBridge.SourcePaths {
  static func defaultPaths(environment: [String: String] = ProcessInfo.processInfo.environment) -> Self {
    let codexHome = environment["CODEX_HOME"]
      .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
      .map { URL(fileURLWithPath: $0, isDirectory: true) }
      ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent(".codex", isDirectory: true)
    return Self(
      stateDatabaseURL: codexHome.appendingPathComponent("state_5.sqlite"),
      globalStateURL: codexHome.appendingPathComponent(".codex-global-state.json")
    )
  }
}

private extension TatwoCodexAppStateBridge {
  struct CodexAssignment: Decodable, Sendable {
    var projectKind: String?
    var projectID: String?
    var path: String?
  }

  struct CodexGlobalState: Decodable, Sendable {
    var projectOrder: [String] = []
    var threadProjectAssignments: [String: CodexAssignment] = [:]
    var threadWorkspaceRootHints: [String: String] = [:]
    var projectlessThreadIDs: [String] = []
    var sidebarProjectThreadOrders: [String: [String: CodexSidebarThreadOrder]] = [:]
    var electronSavedWorkspaceRoots: [String] = []

    enum CodingKeys: String, CodingKey {
      case projectOrder = "project-order"
      case threadProjectAssignments = "thread-project-assignments"
      case threadWorkspaceRootHints = "thread-workspace-root-hints"
      case projectlessThreadIDs = "projectless-thread-ids"
      case sidebarProjectThreadOrders = "sidebar-project-thread-orders"
      case electronSavedWorkspaceRoots = "electron-saved-workspace-roots"
    }

    static func load(from url: URL) -> Self {
      let result = ExternalVolumeReader(rootURL: url.deletingLastPathComponent())
        .readBoundedFileSync(url, maximumBytes: 2 * 1_024 * 1_024)
      guard let data = result.value else { return Self() }
      return (try? JSONDecoder().decode(Self.self, from: data)) ?? Self()
    }

    func savedProjectPathSet() -> Set<String> {
      Set((projectOrder + electronSavedWorkspaceRoots).compactMap(TatwoCodexAppStateBridge.normalizePath))
    }
  }

  struct CodexSidebarThreadOrder: Decodable, Sendable {
    var sortKey: Double?
  }

  struct CodexThreadRow: Decodable, Sendable {
    var id: String
    var rolloutPath: String
    var cwd: String
    var title: String
    var model: String?
    var threadSource: String
    var preview: String
    var createdAt: Int64
    var updatedAt: Int64
    var createdAtMS: Int64?
    var updatedAtMS: Int64?
    var archived: Int

    enum CodingKeys: String, CodingKey {
      case id
      case rolloutPath = "rollout_path"
      case cwd
      case title
      case model
      case threadSource = "thread_source"
      case preview
      case createdAt = "created_at"
      case updatedAt = "updated_at"
      case createdAtMS = "created_at_ms"
      case updatedAtMS = "updated_at_ms"
      case archived
    }

    var isArchived: Bool { archived != 0 }

    func toTatwoThread() -> TatwoNativeChatThread {
      let created = Self.date(ms: createdAtMS, seconds: createdAt)
      let updated = Self.date(ms: updatedAtMS, seconds: updatedAt)
      let safeTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Codex thread" : title
      let safePreview = preview.trimmingCharacters(in: .whitespacesAndNewlines)
      return TatwoNativeChatThread(
        id: UUID(uuidString: id) ?? TatwoCodexAppStateBridge.stableProjectUUID(for: "thread:\(id)"),
        title: safeTitle,
        codexSessionID: id,
        mirroredCodexWorkspacePath: TatwoCodexAppStateBridge.normalizePath(cwd),
        sourceMarker: TatwoNativeChatThreadSourceMarker.codexAppMirror,
        createdAt: created,
        updatedAt: updated,
        isPinned: false,
        isArchived: false,
        lastPreview: safePreview
      )
    }

    private static func date(ms: Int64?, seconds: Int64) -> Date {
      if let ms, ms > 0 { return Date(timeIntervalSince1970: TimeInterval(ms) / 1000.0) }
      return Date(timeIntervalSince1970: TimeInterval(seconds))
    }
  }

  func loadThreadRows() throws -> [CodexThreadRow] {
    guard ExternalVolumeReader(rootURL: sourcePaths.stateDatabaseURL)
      .inspectSync()
      .value?.isRegularFile == true
    else { return [] }
#if os(macOS)
    let query = """
      SELECT id, rollout_path, cwd, substr(title, 1, 180) AS title, model, COALESCE(thread_source, source, '') AS thread_source, substr(preview, 1, 240) AS preview, created_at, updated_at, created_at_ms, updated_at_ms, archived
      FROM threads
      WHERE archived = 0
      ORDER BY COALESCE(NULLIF(recency_at_ms, 0), NULLIF(updated_at_ms, 0), updated_at * 1000) DESC
      LIMIT \(max(1, maxThreadRows));
      """
    let data = try runSQLiteJSON(query: query)
    guard !data.isEmpty else { return [] }
    return try JSONDecoder().decode([CodexThreadRow].self, from: data)
#else
    throw BridgeError.unsupportedPlatform
#endif
  }

  func rolloutPath(for threadID: String) throws -> String? {
    guard ExternalVolumeReader(rootURL: sourcePaths.stateDatabaseURL)
      .inspectSync()
      .value?.isRegularFile == true
    else { return nil }
#if os(macOS)
    guard !Thread.isMainThread else {
      throw BridgeError.mainThreadSubprocessDenied
    }
    let safeThreadID = threadID.replacingOccurrences(of: "'", with: "''")
    let query = """
      SELECT rollout_path
      FROM threads
      WHERE id = '\(safeThreadID)'
      LIMIT 1;
      """
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    process.arguments = ["-readonly", "-noheader", sourcePaths.stateDatabaseURL.path, query]
    let output = Pipe()
    let error = Pipe()
    process.standardOutput = output
    process.standardError = error
    try process.run()
    let out = output.fileHandleForReading.readDataToEndOfFile()
    let err = error.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      let message = String(data: err, encoding: .utf8) ?? "sqlite3 failed"
      throw BridgeError.sqliteCommandFailed(message)
    }
    let path = String(data: out, encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return path.isEmpty ? nil : path
#else
    throw BridgeError.unsupportedPlatform
#endif
  }

#if os(macOS)
  func runSQLiteJSON(query: String) throws -> Data {
    guard !Thread.isMainThread else {
      throw BridgeError.mainThreadSubprocessDenied
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    process.arguments = ["-readonly", "-json", sourcePaths.stateDatabaseURL.path, query]
    let output = Pipe()
    let error = Pipe()
    process.standardOutput = output
    process.standardError = error
    try process.run()
    // Drain stdout/stderr before waiting so large Codex thread previews cannot
    // fill the pipe and deadlock the App launch/export path.
    let out = output.fileHandleForReading.readDataToEndOfFile()
    let err = error.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      let message = String(data: err, encoding: .utf8) ?? "sqlite3 failed"
      throw BridgeError.sqliteCommandFailed(message)
    }
    return out
  }
#endif

  func orderedProjects(globalState: CodexGlobalState, buckets: [String: [TatwoNativeChatThread]]) -> [String] {
    var seen = Set<String>()
    var paths: [String] = []
    func append(_ path: String) {
      guard let normalized = Self.normalizePath(path), !seen.contains(normalized) else { return }
      seen.insert(normalized)
      paths.append(normalized)
    }
    globalState.projectOrder.forEach(append)
    globalState.electronSavedWorkspaceRoots.forEach(append)
    buckets.keys.sorted().forEach(append)
    return paths
  }

  func orderedThreads(projectPath: String, threads: [TatwoNativeChatThread], globalState: CodexGlobalState) -> [TatwoNativeChatThread] {
    let order = globalState.sidebarProjectThreadOrders[projectPath] ?? [:]
    return threads.sorted { lhs, rhs in
      let lhsKey = lhs.codexSessionID.flatMap { order[$0]?.sortKey }
      let rhsKey = rhs.codexSessionID.flatMap { order[$0]?.sortKey }
      switch (lhsKey, rhsKey) {
      case let (l?, r?) where l != r:
        return l > r
      case (_?, nil):
        return true
      case (nil, _?):
        return false
      default:
        return lhs.updatedAt > rhs.updatedAt
      }
    }
  }

  static func normalizedString(_ value: String?) -> String? {
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? nil : trimmed
  }

  static func sameProject(lhs: String, rhs: String) -> Bool {
    normalizePath(lhs) == normalizePath(rhs)
  }

  static func normalizePath(_ value: String?) -> String? {
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !trimmed.isEmpty else { return nil }
    return URL(fileURLWithPath: trimmed, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath().path
  }

  /// Tatwo Chat uses one App-owned workspace rather than a Codex sidebar
  /// project. Codex may omit that thread from `projectless-thread-ids`, so a
  /// valid same-session row would otherwise disappear from Tatwo after the
  /// mirror reload even though its rollout still exists.
  static func isTatwoOwnedChatWorkspace(_ normalizedPath: String?) -> Bool {
    guard let normalizedPath else { return false }
    let components = URL(fileURLWithPath: normalizedPath, isDirectory: true)
      .standardizedFileURL
      .pathComponents
    guard components.count >= 4 else { return false }
    return Array(components.suffix(4)) == [
      "Library",
      "Application Support",
      "Tatwo Ultrawork",
      "chat-workspace",
    ]
  }

  static func projectDisplayName(for path: String) -> String {
    let last = URL(fileURLWithPath: path, isDirectory: true).lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
    return last.isEmpty ? path : last
  }

  static func loadTranscript(
    from rolloutURL: URL,
    maxMessages: Int,
    windowBytes: Int = 6 * 1024 * 1024
  ) throws -> [TatwoNativeChatStoredMessage] {
    let reader = ExternalVolumeReader(rootURL: rolloutURL.deletingLastPathComponent())
    guard let info = reader.inspectSync(rolloutURL).value,
      info.isRegularFile
    else {
      throw BridgeError.transcriptNotFound(rolloutURL.path)
    }
    let fileSize = UInt64(max(0, info.size ?? 0))
    guard fileSize > 0 else { return [] }

    let safeWindow = max(64 * 1024, windowBytes)
    let headLength = min(UInt64(safeWindow), fileSize)
    var messages = parseTranscriptWindow(
      try readWindow(
        from: rolloutURL,
        reader: reader,
        offset: 0,
        length: Int(headLength)
      ),
      dropFirstPartialLine: false)

    if fileSize > headLength {
      let tailLength = min(UInt64(safeWindow), fileSize)
      let tailOffset = fileSize - tailLength
      messages.append(contentsOf: parseTranscriptWindow(
        try readWindow(
          from: rolloutURL,
          reader: reader,
          offset: tailOffset,
          length: Int(tailLength)
        ),
        dropFirstPartialLine: tailOffset > 0))
    }

    var seen = Set<String>()
    let unique = messages.filter { message in
      let key = "\(message.id)|\(message.role)|\(message.createdAt.timeIntervalSince1970)"
      guard !seen.contains(key) else { return false }
      seen.insert(key)
      return true
    }
    .sorted { lhs, rhs in lhs.createdAt < rhs.createdAt }

    guard unique.count > maxMessages, maxMessages > 0 else {
      return maxMessages > 0 ? unique : []
    }
    let headCount = min(8, max(1, maxMessages / 5))
    let tailCount = max(0, maxMessages - headCount)
    return Array(unique.prefix(headCount)) + Array(unique.suffix(tailCount))
  }

  private static func readWindow(
    from url: URL,
    reader: ExternalVolumeReader,
    offset: UInt64,
    length: Int
  ) throws -> Data {
    guard let data = reader.readFileWindowSync(
      url,
      offset: offset,
      length: length
    ).value else {
      throw BridgeError.transcriptNotFound(url.path)
    }
    return data
  }

  static func parseTranscriptWindow(_ data: Data, dropFirstPartialLine: Bool) -> [TatwoNativeChatStoredMessage] {
    guard !data.isEmpty else { return [] }
    var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
    if dropFirstPartialLine, !lines.isEmpty {
      lines.removeFirst()
    }

    let fractionalFormatter = ISO8601DateFormatter()
    fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let plainFormatter = ISO8601DateFormatter()
    plainFormatter.formatOptions = [.withInternetDateTime]

    return lines.compactMap { line -> TatwoNativeChatStoredMessage? in
      let prefix = String(decoding: line.prefix(640), as: UTF8.self)
      guard (prefix.contains("\"type\":\"response_item\"") || prefix.contains("\"type\": \"response_item\"")),
            (prefix.contains("\"type\":\"message\"") || prefix.contains("\"type\": \"message\""))
      else { return nil }
      guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
            (object["type"] as? String) == "response_item",
            let payload = object["payload"] as? [String: Any],
            (payload["type"] as? String) == "message",
            let rawRole = payload["role"] as? String
      else { return nil }

      let normalizedRole = rawRole.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      guard normalizedRole == "user" || normalizedRole == "assistant" else { return nil }

      let text = transcriptText(from: payload["content"])
      guard let safeText = cleanedTranscriptText(
        text,
        normalizedRole: normalizedRole)
      else { return nil }
      let timestampText = object["timestamp"] as? String
      let createdAt = timestampText.flatMap { fractionalFormatter.date(from: $0) ?? plainFormatter.date(from: $0) } ?? Date()
      let stableID = (payload["id"] as? String)
        ?? stableProjectUUID(for: "message:\(normalizedRole):\(createdAt.timeIntervalSince1970):\(safeText.prefix(240))").uuidString.lowercased()

      return TatwoNativeChatStoredMessage(
        id: stableID,
        role: normalizedRole,
        text: safeText,
        status: nil,
        modelID: nil,
        eventKind: .message,
        createdAt: createdAt)
    }
  }

  static func transcriptText(from rawContent: Any?) -> String {
    guard let content = rawContent as? [[String: Any]] else { return "" }
    return content.compactMap { item in
      guard let type = item["type"] as? String,
            type == "input_text" || type == "output_text",
            let text = item["text"] as? String
      else { return nil }
      return text
    }
    .joined(separator: "\n\n")
  }

  static func cleanedTranscriptText(
    _ rawText: String,
    normalizedRole: String? = nil
  ) -> String? {
    let presentationRole: TatwoChatTranscriptRole =
      normalizedRole == "user" ? .user : .assistant
    let presentationSafe =
      TatwoChatTranscriptPresentation.cleanedTranscriptSource(
        rawText,
        role: presentationRole)
    let sanitized = presentationSafe.replacingOccurrences(
      of: #"<codex_internal_context\b[\s\S]*?</codex_internal_context>"#,
      with: "",
      options: .regularExpression)
    let trimmed = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if trimmed.hasPrefix("<codex_internal_context")
      || trimmed.contains("<codex_internal_context")
      || trimmed.hasPrefix("# AGENTS.md instructions")
      || trimmed.hasPrefix("## Handoff Summary")
      || trimmed.hasPrefix("<permissions instructions>")
      || trimmed.hasPrefix("<app-context>")
      || trimmed.hasPrefix("<subagent_notification>")
      || trimmed.contains("<environment_context>")
      || trimmed.contains("Another language model started to solve this problem")
      || looksLikeInternalDelegationPrompt(trimmed) {
      return nil
    }
    let maxCount = 12_000
    guard trimmed.count > maxCount else { return trimmed }
    return "\(trimmed.prefix(maxCount))\n…"
  }

  static func looksLikeInternalDelegationPrompt(_ text: String) -> Bool {
    if text.hasPrefix("你是 Loops 執行手")
      || text.hasPrefix("你是 Loops")
      || text.hasPrefix("You are Loops Executor")
      || text.hasPrefix("You are a Loops Executor") {
      return true
    }
    let lower = text.lowercased()
    return lower.contains("contractid=contract-")
      && (text.contains("完成即停") || lower.contains("finish and stop"))
      && (text.contains("禁止一切 git") || lower.contains("do not run git"))
  }

  static func isVisibleSidebarRow(_ row: CodexThreadRow) -> Bool {
    let source = row.threadSource.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard source != "subagent" else { return false }

    let title = row.title.trimmingCharacters(in: .whitespacesAndNewlines)
    let preview = row.preview.trimmingCharacters(in: .whitespacesAndNewlines)
    let combined = [title, preview].filter { !$0.isEmpty }.joined(separator: "\n")
    guard !combined.isEmpty else { return false }

    if looksLikeInternalDelegationPrompt(combined) { return false }

    let lower = combined.lowercased()
    if lower.hasPrefix("[hidden tatwo ")
      || lower.contains("[hidden tatwo chat interface contract")
      || lower.contains("[hidden tatwo work os contract context") {
      return false
    }

    if lower.hasPrefix("codex reply only ok_")
      || lower.contains("codex reply only ok_")
      || lower.contains("reply only ok")
      || lower.contains("只回 ok")
      || lower.contains("請只回 ok")
      || lower.contains("只回 route_ok")
      || lower.contains("只回 tatwo_")
      || lower.contains("reply_ok")
      || (lower.contains("路線測試") && lower.contains("只回") && lower.contains("_ok"))
      || (lower.contains("do not create goalrun") && lower.contains("ok"))
      || (lower.contains("不要建立 goalrun") && lower.contains("ok")) {
      return false
    }

    // Sidecar/debug prompts can be created as ordinary user threads when they
    // are launched through a bridge instead of the Codex subagent source. They
    // should not become visible Chat products in OS App's Codex-like sidebar.
    if (lower.contains("you are sonnet5") || lower.contains("你是 sonnet5") || lower.contains("你是 loops 執行手"))
      && (lower.contains("repo:") || lower.contains("repo：") || lower.contains("只讀") || lower.contains("副審")) {
      return false
    }

    return true
  }

  static func stableProjectUUID(for seed: String) -> UUID {
    var hash1: UInt64 = 0xcbf29ce484222325
    var hash2: UInt64 = 0x84222325cbf29ce4
    for byte in seed.utf8 {
      hash1 ^= UInt64(byte)
      hash1 &*= 0x100000001b3
      hash2 &+= UInt64(byte) &* 0x9e3779b185ebca87
      hash2 = (hash2 << 13) | (hash2 >> 51)
    }
    var bytes = [UInt8](repeating: 0, count: 16)
    for i in 0..<8 { bytes[i] = UInt8((hash1 >> UInt64((7 - i) * 8)) & 0xff) }
    for i in 0..<8 { bytes[8 + i] = UInt8((hash2 >> UInt64((7 - i) * 8)) & 0xff) }
    bytes[6] = (bytes[6] & 0x0f) | 0x50
    bytes[8] = (bytes[8] & 0x3f) | 0x80
    return UUID(uuid: (
      bytes[0], bytes[1], bytes[2], bytes[3],
      bytes[4], bytes[5], bytes[6], bytes[7],
      bytes[8], bytes[9], bytes[10], bytes[11],
      bytes[12], bytes[13], bytes[14], bytes[15]
    ))
  }
}
