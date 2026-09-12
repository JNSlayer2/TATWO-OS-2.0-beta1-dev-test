import Foundation

/// 一列 canonical 技能庫目錄掃描結果。
public struct TatwoSkillsDirectoryEntryV1: Identifiable, Codable, Sendable, Equatable {
  /// 目錄名。
  public let id: String
  /// SKILL.md front-matter `name`；無則回退目錄名。
  public let name: String
  /// front-matter `description` 首行。
  public let summary: String?
  /// 技能目錄絕對路徑。
  public let path: String
  /// SKILL.md 是否存在。
  public let hasManifest: Bool
  /// 是否已出現在 plugin registry。
  public let isRegistered: Bool
  /// Top-level canonical symlink 的解析後目錄。一般目錄為 nil，portable
  /// identity 與 registry 仍使用 `path`。
  public let snapshotSourcePath: String?

  public init(
    id: String,
    name: String,
    summary: String?,
    path: String,
    hasManifest: Bool,
    isRegistered: Bool,
    snapshotSourcePath: String? = nil
  ) {
    self.id = id
    self.name = name
    self.summary = summary
    self.path = path
    self.hasManifest = hasManifest
    self.isRegistered = isRegistered
    self.snapshotSourcePath = snapshotSourcePath
  }

  /// Immutable snapshot 讀取實體目錄；不改變 portable canonical path。
  public var snapshotSourceURL: URL {
    URL(
      fileURLWithPath: snapshotSourcePath ?? path,
      isDirectory: true
    )
  }

  public var usesLinkedSnapshotSource: Bool {
    snapshotSourcePath != nil
  }
}

/// canonical 技能庫目錄掃描器。fail-soft：root 不存在或不可讀時回空陣列，不丟錯。
public struct TatwoSkillsDirectoryCatalog: Sendable {
  public static let environmentKey = "TATWO_SKILLS_CANONICAL_DIR"
  public static let manifestFileName = "SKILL.md"
  /// loadDetail 全文上限（64KB），超過截斷。
  public static let detailByteLimit = 64 * 1024

  public let rootURL: URL

  public init(rootURL: URL) {
    self.rootURL = rootURL
  }

  /// 預設 root：只接受 caller/environment 注入；沒有設定時使用本機
  /// Application Support 下的空 canonical 目錄。這避免 production source
  /// 偷帶入某一台機器的外接卷絕對路徑。
  public static func defaultRoot(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> URL {
    if let override = environment[environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
       !override.isEmpty {
      return URL(fileURLWithPath: override, isDirectory: true)
    }
    return TatwoRuntimeLayout.applicationSupportRoot(environment: environment)
      .appendingPathComponent("skills", isDirectory: true)
  }

  /// root 目錄是否存在且是目錄。
  public func rootIsAvailable() -> Bool {
    ExternalVolumeReader(rootURL: rootURL).inspectSync().value?.isDirectory == true
  }

  /// 掃描 root 下所有技能目錄；名稱升冪排序。fail-soft 回 []。
  public func scan(registeredPaths: Set<String>) -> [TatwoSkillsDirectoryEntryV1] {
    scanOutcome(registeredPaths: registeredPaths).value ?? []
  }

  /// Same scan with volume state preserved for feature-hidden UI.
  public func scanOutcome(
    registeredPaths: Set<String>,
    reader: ExternalVolumeReader? = nil
  ) -> ExternalReadOutcome<[TatwoSkillsDirectoryEntryV1]> {
    let reader = reader ?? ExternalVolumeReader(rootURL: rootURL)
    let rootResult = reader.inspectSync()
    guard let rootInfo = rootResult.value, rootInfo.isDirectory else {
      return Self.mapOutcome(rootResult, value: nil)
    }
    let listResult = reader.readDirectorySync()
    guard let children = listResult.value else {
      return Self.mapOutcome(listResult, value: nil)
    }

    let normalizedRegistered = Set(registeredPaths.map(Self.normalizePath))
    var entries: [TatwoSkillsDirectoryEntryV1] = []
    for childEntry in children {
      let child = childEntry.url
      guard Self.isDirectoryOrDirectorySymlink(
        childEntry,
        reader: reader
      ) else {
        continue
      }
      let directoryName = child.lastPathComponent
      let manifestURL = child.appendingPathComponent(Self.manifestFileName)
      let manifestProbe = reader.inspectSync(manifestURL)
      let hasManifest = manifestProbe.value?.isRegularFile == true
      var frontMatter = FrontMatter()
      if hasManifest,
         let data = reader.readBoundedFileSync(
           manifestURL,
           maximumBytes: Self.detailByteLimit
         ).value,
         let text = String(data: data, encoding: .utf8) {
        frontMatter = Self.parseFrontMatter(text)
      }
      let path = child.path
      let snapshotSourcePath = childEntry.info.isSymbolicLink
        ? child.resolvingSymlinksInPath().standardizedFileURL.path
        : nil
      entries.append(
        TatwoSkillsDirectoryEntryV1(
          id: directoryName,
          name: frontMatter.name ?? directoryName,
          summary: frontMatter.descriptionFirstLine,
          path: path,
          hasManifest: hasManifest,
          isRegistered: normalizedRegistered.contains(Self.normalizePath(path)),
          snapshotSourcePath: snapshotSourcePath
        )
      )
    }
    let sorted = entries.sorted {
      $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
    }
    return ExternalReadOutcome(
      value: sorted,
      state: .fresh,
      access: listResult.access,
      sourceKey: listResult.sourceKey,
      elapsedMs: max(rootResult.elapsedMs, listResult.elapsedMs)
    )
  }

  /// Canonical skill roots intentionally support a top-level symlink whose
  /// target is a readable directory. Keep the entry's lexical path/ID for
  /// portable repository identity, while rejecting broken links and links to
  /// files. Nested payload symlinks remain governed by the Skillet snapshot
  /// verifier and are not relaxed here.
  private static func isDirectoryOrDirectorySymlink(
    _ entry: ExternalVolumeDirectoryEntry,
    reader: ExternalVolumeReader
  ) -> Bool {
    if entry.info.isDirectory {
      return true
    }
    guard entry.info.isSymbolicLink else {
      return false
    }
    return reader.inspectSync(entry.url.resolvingSymlinksInPath()).value?.isDirectory == true
  }

  /// lazy 讀該技能的 SKILL.md 全文；超過 64KB 截斷；讀不到回 nil。
  public func loadDetail(id: String) -> String? {
    loadDetailOutcome(id: id).value
  }

  public func loadDetailOutcome(
    id: String,
    reader: ExternalVolumeReader? = nil
  ) -> ExternalReadOutcome<String> {
    let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !trimmed.contains("/"), trimmed != "..", trimmed != "." else {
      let key = ExternalVolumeReader.sourceKey(for: rootURL, logicalResource: "detail:\(id)")
      return ExternalReadOutcome(
        value: nil,
        state: .unavailable,
        failure: .ioError,
        sourceKey: key,
        diagnosticCode: "invalid-skill-id")
    }
    let manifestURL = rootURL
      .appendingPathComponent(trimmed, isDirectory: true)
      .appendingPathComponent(Self.manifestFileName)
    let reader = reader ?? ExternalVolumeReader(rootURL: rootURL)
    let readResult = reader.readBoundedFileSync(
      manifestURL,
      maximumBytes: Self.detailByteLimit + 1
    )
    guard var data = readResult.value else {
      return Self.mapOutcome(readResult, value: nil)
    }
    var truncated = false
    if data.count > Self.detailByteLimit {
      data = data.prefix(Self.detailByteLimit)
      truncated = true
    }
    guard var text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
    else {
      return Self.mapOutcome(readResult, value: nil, diagnosticCode: "invalid-utf8")
    }
    if truncated {
      text += "\n…（內容超過 64KB，已截斷）"
    }
    return Self.mapOutcome(readResult, value: text)
  }

  private static func mapOutcome<T, V>(
    _ outcome: ExternalReadOutcome<T>,
    value: V?,
    diagnosticCode: String? = nil
  ) -> ExternalReadOutcome<V> where T: Sendable, V: Sendable {
    ExternalReadOutcome(
      value: value,
      state: outcome.state,
      access: outcome.access,
      failure: outcome.failure,
      lastGoodAt: outcome.lastGoodAt,
      sourceKey: outcome.sourceKey,
      elapsedMs: outcome.elapsedMs,
      diagnosticCode: diagnosticCode ?? outcome.diagnosticCode
    )
  }

  // MARK: - Front matter

  struct FrontMatter {
    var name: String?
    var descriptionFirstLine: String?
  }

  /// 樸素逐行解析：只認第一個 `---` 區塊內的 `name:` 與 `description:` 兩鍵。
  static func parseFrontMatter(_ text: String) -> FrontMatter {
    var result = FrontMatter()
    let lines = text.components(separatedBy: .newlines)
    var index = 0
    // 跳過開頭空行後，第一個非空行必須是 ---
    while index < lines.count,
          lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
      index += 1
    }
    guard index < lines.count,
          lines[index].trimmingCharacters(in: .whitespaces) == "---"
    else {
      return result
    }
    index += 1
    var closed = false
    var name: String?
    var description: String?
    while index < lines.count {
      let line = lines[index]
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed == "---" {
        closed = true
        break
      }
      if name == nil, let value = keyedValue(trimmed, key: "name") {
        name = value
      } else if description == nil, let value = keyedValue(trimmed, key: "description") {
        description = value
      }
      index += 1
    }
    // 沒有關閉的 --- 視為壞 front-matter，不採用。
    guard closed else { return result }
    result.name = name
    result.descriptionFirstLine = description
    return result
  }

  private static func keyedValue(_ line: String, key: String) -> String? {
    let prefix = key + ":"
    guard line.hasPrefix(prefix) else { return nil }
    var value = String(line.dropFirst(prefix.count))
      .trimmingCharacters(in: .whitespaces)
    // 去除成對引號
    if value.count >= 2,
       (value.hasPrefix("\"") && value.hasSuffix("\""))
        || (value.hasPrefix("'") && value.hasSuffix("'")) {
      value = String(value.dropFirst().dropLast())
        .trimmingCharacters(in: .whitespaces)
    }
    // 只取首行（本解析逐行，天然單行；保底再切一次）
    if let firstLine = value.components(separatedBy: .newlines).first {
      value = firstLine.trimmingCharacters(in: .whitespaces)
    }
    return value.isEmpty ? nil : value
  }

  private static func normalizePath(_ path: String) -> String {
    let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed != "/" else { return trimmed }
    var normalized = (trimmed as NSString).standardizingPath
    while normalized.count > 1, normalized.hasSuffix("/") {
      normalized = String(normalized.dropLast())
    }
    return normalized
  }
}
