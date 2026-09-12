import Foundation

/// Visible source state for the curated-memory projection.
///
/// `stale` is never equivalent to `fresh`: it only means a last-good cache was
/// returned after the configured source became unavailable.
public enum TatwoCuratedMemoryReadStateV1: Codable, Sendable, Equatable {
  case fresh
  case gracefulEmpty
  case stale(since: Date)
  case unavailable(reason: ExternalVolumeFailure)
}

/// App-facing metadata parsed from one file in the GBrain `curated` layer.
/// This is data only; it intentionally carries no trust, authority, or
/// adjudication assertion.
public struct TatwoCuratedPageSummaryV1: Codable, Sendable, Identifiable, Equatable {
  public var id: String { slug }

  public let slug: String
  public let title: String
  public let updatedAt: Date?
  public let tags: [String]
  public let excerpt: String

  public init(
    slug: String,
    title: String,
    updatedAt: Date?,
    tags: [String],
    excerpt: String
  ) {
    self.slug = slug
    self.title = title
    self.updatedAt = updatedAt
    self.tags = tags
    self.excerpt = excerpt
  }
}

public struct TatwoCuratedPageListV1: Codable, Sendable, Equatable {
  public let pages: [TatwoCuratedPageSummaryV1]
  public let state: TatwoCuratedMemoryReadStateV1
  /// Present when `stale` was caused by an external-source failure.
  public let sourceFailure: ExternalVolumeFailure?

  public init(
    pages: [TatwoCuratedPageSummaryV1],
    state: TatwoCuratedMemoryReadStateV1,
    sourceFailure: ExternalVolumeFailure? = nil
  ) {
    self.pages = pages
    self.state = state
    self.sourceFailure = sourceFailure
  }
}

public struct TatwoCuratedPageV1: Codable, Sendable, Equatable {
  public let summary: TatwoCuratedPageSummaryV1
  public let content: String

  public init(summary: TatwoCuratedPageSummaryV1, content: String) {
    self.summary = summary
    self.content = content
  }
}

public struct TatwoCuratedPageReadV1: Codable, Sendable, Equatable {
  public let page: TatwoCuratedPageV1?
  public let state: TatwoCuratedMemoryReadStateV1
  /// Present when `stale` was caused by an external-source failure.
  public let sourceFailure: ExternalVolumeFailure?

  public init(
    page: TatwoCuratedPageV1?,
    state: TatwoCuratedMemoryReadStateV1,
    sourceFailure: ExternalVolumeFailure? = nil
  ) {
    self.page = page
    self.state = state
    self.sourceFailure = sourceFailure
  }
}

/// Read-only projection of GBrain's curated layer for App consumption.
///
/// There is deliberately no public write/refresh/ingest API. Source reads are
/// bounded and routed through `ExternalVolumeReader`. The only mutation this
/// type may perform is replacing its private last-good cache.
public struct TatwoCuratedMemoryReaderV1 {
  public static let osRootEnvironmentKey = "TATWO_OS_ROOT"
  public static let localRootFileName = "os-root.local.json"
  public static let defaultMaximumPageBytes = 512 * 1_024
  public static let defaultMaximumPages = 512

  private static let curatedDirectoryName = "curated"
  private static let cacheFileName = "curated-memory-last-good-v1.json"

  public let rootURL: URL?
  public let cacheURL: URL?
  public let maximumPageBytes: Int

  private let fileManager: FileManager
  private let externalReader: ExternalVolumeReader?
  private let now: @Sendable () -> Date

  /// Uses the F10 resolution order:
  /// `TATWO_OS_ROOT` -> App Support `os-root.local.json` -> unconfigured.
  /// The local file may override `gbrainRoot`; otherwise `<osRoot>/gbrain` is
  /// used. An unconfigured root returns `gracefulEmpty` and is not an error.
  public init(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    applicationSupportBase: URL? = nil,
    fileManager: FileManager = .default,
    policy: ExternalReadPolicy = .standard,
    maximumPageBytes: Int = TatwoCuratedMemoryReaderV1.defaultMaximumPageBytes,
    maximumPages: Int = TatwoCuratedMemoryReaderV1.defaultMaximumPages,
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    let appSupport = TatwoRuntimeLayout.applicationSupportRoot(
      environment: environment,
      applicationSupportBase: applicationSupportBase,
      fileManager: fileManager)
    let resolvedRoot = Self.resolveGBrainRoot(
      environment: environment,
      applicationSupportRoot: appSupport,
      fileManager: fileManager)

    self.rootURL = resolvedRoot
    self.cacheURL = appSupport
      .appendingPathComponent("cache", isDirectory: true)
      .appendingPathComponent(Self.cacheFileName, isDirectory: false)
    self.maximumPageBytes = max(1, maximumPageBytes)
    self.fileManager = fileManager
    self.externalReader = resolvedRoot.map {
      ExternalVolumeReader(
        rootURL: $0,
        policy: ExternalReadPolicy(
          allowExternalVolumes: policy.allowExternalVolumes,
          timeout: policy.timeout,
          maximumEntries: maximumPages),
        fileSystem: FileManagerExternalVolumeFileSystem(fileManager: fileManager),
        now: now)
    }
    self.now = now
  }

  /// Explicit root injection for tests and non-App hosts. `rootURL` is the
  /// GBrain root itself; only its `curated` child is ever traversed.
  public init(
    rootURL: URL?,
    cacheURL: URL? = nil,
    maximumPageBytes: Int = TatwoCuratedMemoryReaderV1.defaultMaximumPageBytes,
    fileManager: FileManager = .default,
    externalReader: ExternalVolumeReader? = nil,
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    let standardized = rootURL.map(Self.normalizedFileURLPreservingPath)
    self.rootURL = standardized
    self.cacheURL = cacheURL.map(Self.normalizedFileURLPreservingPath)
    self.maximumPageBytes = max(1, maximumPageBytes)
    self.fileManager = fileManager
    self.externalReader = standardized.map {
      externalReader
        ?? ExternalVolumeReader(
          rootURL: $0,
          fileSystem: FileManagerExternalVolumeFileSystem(fileManager: fileManager),
          now: now)
    }
    self.now = now
  }

  public func list() -> TatwoCuratedPageListV1 {
    guard let rootURL, let externalReader else {
      return TatwoCuratedPageListV1(pages: [], state: .gracefulEmpty)
    }

    let curatedGate = curatedDirectory(
      rootURL: rootURL,
      externalReader: externalReader)
    guard let curatedURL = curatedGate.url else {
      return cachedListOrUnavailable(failure: curatedGate.failure ?? .ioError)
    }

    let directory = externalReader.readDirectorySync(curatedURL)
    guard let entries = directory.value else {
      return cachedListOrUnavailable(failure: normalizedFailure(directory.failure))
    }

    var pages: [TatwoCuratedPageSummaryV1] = []
    var contents: [String: String] = [:]
    var firstFailure: ExternalVolumeFailure?

    for entry in entries {
      guard isSupportedCuratedFile(entry, within: curatedURL) else { continue }
      let read = externalReader.readBoundedFileSync(
        entry.url,
        maximumBytes: maximumPageBytes + 1)
      guard let data = read.value, data.count <= maximumPageBytes else {
        firstFailure = firstFailure ?? normalizedFailure(read.failure)
        continue
      }
      guard let content = String(data: data, encoding: .utf8) else {
        firstFailure = firstFailure ?? .ioError
        continue
      }
      let summary = Self.summary(
        for: entry.url,
        content: content,
        fallbackUpdatedAt: entry.info.modifiedAt)
      pages.append(summary)
      contents[summary.slug] = content
    }

    if let firstFailure {
      return cachedListOrUnavailable(failure: firstFailure)
    }

    pages.sort {
      switch ($0.updatedAt, $1.updatedAt) {
      case let (lhs?, rhs?) where lhs != rhs:
        return lhs > rhs
      default:
        return $0.slug.localizedStandardCompare($1.slug) == .orderedAscending
      }
    }
    saveCache(pages: pages, mergingContents: contents, replacingPageSet: true)
    return TatwoCuratedPageListV1(pages: pages, state: .fresh)
  }

  /// Returns the full UTF-8 contents of one curated page.
  /// Slugs are single path components without an extension. Raw/truth paths,
  /// absolute paths, traversal, and symlink escapes are rejected without I/O.
  public func page(_ slug: String) -> TatwoCuratedPageReadV1 {
    guard Self.isValidSlug(slug) else {
      return TatwoCuratedPageReadV1(
        page: nil,
        state: .unavailable(reason: .ioError),
        sourceFailure: .ioError)
    }
    guard let rootURL, let externalReader else {
      return TatwoCuratedPageReadV1(page: nil, state: .gracefulEmpty)
    }

    let curatedGate = curatedDirectory(
      rootURL: rootURL,
      externalReader: externalReader)
    guard let curatedURL = curatedGate.url else {
      return cachedPageOrUnavailable(
        slug: slug,
        failure: curatedGate.failure ?? .ioError)
    }
    let directory = externalReader.readDirectorySync(curatedURL)
    guard let entries = directory.value else {
      return cachedPageOrUnavailable(slug: slug, failure: normalizedFailure(directory.failure))
    }

    guard let entry = entries.first(where: {
      isSupportedCuratedFile($0, within: curatedURL)
        && $0.url.deletingPathExtension().lastPathComponent == slug
    }) else {
      return TatwoCuratedPageReadV1(
        page: nil,
        state: .unavailable(reason: .volumeAbsent),
        sourceFailure: .volumeAbsent)
    }

    let read = externalReader.readBoundedFileSync(
      entry.url,
      maximumBytes: maximumPageBytes + 1)
    guard let data = read.value, data.count <= maximumPageBytes,
      let content = String(data: data, encoding: .utf8)
    else {
      return cachedPageOrUnavailable(slug: slug, failure: normalizedFailure(read.failure))
    }

    let summary = Self.summary(
      for: entry.url,
      content: content,
      fallbackUpdatedAt: entry.info.modifiedAt)
    saveCache(pages: [summary], mergingContents: [slug: content])
    return TatwoCuratedPageReadV1(
      page: TatwoCuratedPageV1(summary: summary, content: content),
      state: .fresh)
  }

  public func page(slug: String) -> TatwoCuratedPageReadV1 {
    page(slug)
  }

  private struct LocalRootFile: Decodable {
    let osRoot: String?
    let gbrainRoot: String?
  }

  private struct LastGoodCache: Codable {
    var sourceKey: String
    var savedAt: Date
    var pages: [TatwoCuratedPageSummaryV1]
    var contents: [String: String]
  }

  private static func resolveGBrainRoot(
    environment: [String: String],
    applicationSupportRoot: URL,
    fileManager: FileManager
  ) -> URL? {
    let local = loadLocalRootFile(
      applicationSupportRoot: applicationSupportRoot,
      fileManager: fileManager)
    let osRootPath = nonempty(environment[osRootEnvironmentKey]) ?? nonempty(local?.osRoot)
    guard let osRootPath else { return nil }

    if let override = nonempty(local?.gbrainRoot) {
      // Do not force isDirectory here: a path string from config may or may not
      // include a trailing slash. Rebuild via standardized path so `/root` and
      // `/root/` collapse before any later path comparison.
      return normalizedFileURLPreservingPath(URL(fileURLWithPath: override))
    }
    // Derived gbrain root keeps directory URL convention (trailing slash).
    return URL(fileURLWithPath: osRootPath, isDirectory: true)
      .appendingPathComponent("gbrain", isDirectory: true)
      .standardizedFileURL
  }

  /// Standardize a file URL without inventing directory trailing-slash semantics.
  /// Config/path strings round-trip through `.path` so slash variants collapse.
  private static func normalizedFileURLPreservingPath(_ url: URL) -> URL {
    let standardized = url.standardizedFileURL
    return URL(fileURLWithPath: standardized.path)
  }

  /// Path form used for all prefix/containment checks (both sides same helper).
  /// Trailing slashes are insignificant because Foundation `.path` drops them.
  private static func normalizedPath(_ url: URL) -> String {
    url.resolvingSymlinksInPath().standardizedFileURL.path
  }

  /// True when `candidate` is `directory` or a path under it (slash-safe).
  private static func isPath(_ candidate: URL, withinDirectory directory: URL) -> Bool {
    let base = normalizedPath(directory)
    let basePrefix = base.hasSuffix("/") ? base : base + "/"
    let candidatePath = normalizedPath(candidate)
    return candidatePath == base || candidatePath.hasPrefix(basePrefix)
  }

  private static func loadLocalRootFile(
    applicationSupportRoot: URL,
    fileManager: FileManager
  ) -> LocalRootFile? {
    let url = applicationSupportRoot.appendingPathComponent(localRootFileName)
    guard fileManager.fileExists(atPath: url.path),
      let data = try? Data(contentsOf: url)
    else { return nil }
    return try? JSONDecoder().decode(LocalRootFile.self, from: data)
  }

  private static func nonempty(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
      !value.isEmpty
    else { return nil }
    return value
  }

  private func isSupportedCuratedFile(
    _ entry: ExternalVolumeDirectoryEntry,
    within curatedURL: URL
  ) -> Bool {
    guard entry.info.isRegularFile, !entry.info.isSymbolicLink,
      ["md", "json"].contains(entry.url.pathExtension.lowercased())
    else { return false }
    return Self.isPath(entry.url, withinDirectory: curatedURL)
  }

  private func curatedDirectory(
    rootURL: URL,
    externalReader: ExternalVolumeReader
  ) -> (url: URL?, failure: ExternalVolumeFailure?) {
    let rootProbe = externalReader.inspectSync(rootURL)
    guard rootProbe.value?.isDirectory == true else {
      return (nil, normalizedFailure(rootProbe.failure))
    }

    let curatedURL = rootURL.appendingPathComponent(
      Self.curatedDirectoryName,
      isDirectory: true)
    let curatedProbe = externalReader.inspectSync(curatedURL)
    guard let info = curatedProbe.value,
      info.isDirectory,
      !info.isSymbolicLink
    else {
      return (nil, normalizedFailure(curatedProbe.failure))
    }

    // curated must be a real child of root (not the root itself).
    let resolvedRoot = Self.normalizedPath(rootURL)
    let resolvedCurated = Self.normalizedPath(curatedURL)
    let rootPrefix = resolvedRoot.hasSuffix("/") ? resolvedRoot : resolvedRoot + "/"
    guard resolvedCurated.hasPrefix(rootPrefix) else {
      return (nil, .ioError)
    }
    return (curatedURL, nil)
  }

  private static func isValidSlug(_ slug: String) -> Bool {
    guard !slug.isEmpty, slug != ".", slug != "..",
      !slug.contains("/"), !slug.contains("\\"),
      !slug.contains("\0"), (slug as NSString).pathExtension.isEmpty
    else { return false }
    return true
  }

  private static func summary(
    for url: URL,
    content: String,
    fallbackUpdatedAt: Date?
  ) -> TatwoCuratedPageSummaryV1 {
    let slug = url.deletingPathExtension().lastPathComponent
    if url.pathExtension.lowercased() == "json",
      let data = content.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    {
      let title = nonempty(object["title"] as? String) ?? slug
      let tags = normalizedTags(object["tags"])
      let updated = parseDate(
        (object["updatedAt"] as? String)
          ?? (object["updated_at"] as? String)
          ?? (object["adjudicated_at"] as? String)) ?? fallbackUpdatedAt
      let body = nonempty(object["content"] as? String)
        ?? nonempty(object["body"] as? String)
        ?? nonempty(object["excerpt"] as? String)
        ?? ""
      return TatwoCuratedPageSummaryV1(
        slug: slug,
        title: title,
        updatedAt: updated,
        tags: tags,
        excerpt: excerpt(body))
    }

    let parsed = parseMarkdown(content)
    return TatwoCuratedPageSummaryV1(
      slug: slug,
      title: nonempty(parsed.fields["title"])
        ?? firstHeading(parsed.body)
        ?? slug,
      updatedAt: parseDate(
        parsed.fields["updatedAt"]
          ?? parsed.fields["updated_at"]
          ?? parsed.fields["adjudicated_at"])
        ?? fallbackUpdatedAt,
      tags: normalizedTags(parsed.fields["tags"]),
      excerpt: excerpt(parsed.body))
  }

  private static func parseMarkdown(_ content: String) -> (
    fields: [String: String], body: String
  ) {
    let lines = content.components(separatedBy: .newlines)
    guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
      let end = lines.dropFirst().firstIndex(where: {
        $0.trimmingCharacters(in: .whitespaces) == "---"
      })
    else { return ([:], content) }

    var fields: [String: String] = [:]
    for line in lines[1..<end] {
      guard let colon = line.firstIndex(of: ":") else { continue }
      let key = line[..<colon].trimmingCharacters(in: .whitespaces)
      let value = line[line.index(after: colon)...]
        .trimmingCharacters(in: .whitespaces)
        .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
      if !key.isEmpty { fields[key] = value }
    }
    return (fields, lines[(end + 1)...].joined(separator: "\n"))
  }

  private static func firstHeading(_ body: String) -> String? {
    for line in body.components(separatedBy: .newlines) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard trimmed.hasPrefix("#") else { continue }
      let heading = trimmed.drop(while: { $0 == "#" })
        .trimmingCharacters(in: .whitespaces)
      if !heading.isEmpty { return heading }
    }
    return nil
  }

  private static func normalizedTags(_ value: Any?) -> [String] {
    if let tags = value as? [String] {
      return Array(Set(tags.compactMap(nonempty))).sorted()
    }
    guard var text = value as? String else { return [] }
    text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.hasPrefix("[") && text.hasSuffix("]") {
      text.removeFirst()
      text.removeLast()
    }
    return Array(Set(text.split(separator: ",").compactMap {
      nonempty(String($0).trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")))
    })).sorted()
  }

  private static func parseDate(_ value: String?) -> Date? {
    guard let value = nonempty(value) else { return nil }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: value) { return date }
    return ISO8601DateFormatter().date(from: value)
  }

  private static func excerpt(_ body: String) -> String {
    let visible = body.components(separatedBy: .newlines)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty && !$0.hasPrefix("#") }
      .joined(separator: " ")
      .replacingOccurrences(of: "  ", with: " ")
    guard visible.count > 280 else { return visible }
    let end = visible.index(visible.startIndex, offsetBy: 280)
    return String(visible[..<end]).trimmingCharacters(in: .whitespaces) + "…"
  }

  private func normalizedFailure(_ failure: ExternalVolumeFailure?) -> ExternalVolumeFailure {
    failure ?? .ioError
  }

  private func cachedListOrUnavailable(
    failure: ExternalVolumeFailure
  ) -> TatwoCuratedPageListV1 {
    if let cache = loadCache() {
      return TatwoCuratedPageListV1(
        pages: cache.pages,
        state: .stale(since: cache.savedAt),
        sourceFailure: failure)
    }
    return TatwoCuratedPageListV1(
      pages: [],
      state: .unavailable(reason: failure),
      sourceFailure: failure)
  }

  private func cachedPageOrUnavailable(
    slug: String,
    failure: ExternalVolumeFailure
  ) -> TatwoCuratedPageReadV1 {
    if let cache = loadCache(),
      let summary = cache.pages.first(where: { $0.slug == slug }),
      let content = cache.contents[slug]
    {
      return TatwoCuratedPageReadV1(
        page: TatwoCuratedPageV1(summary: summary, content: content),
        state: .stale(since: cache.savedAt),
        sourceFailure: failure)
    }
    return TatwoCuratedPageReadV1(
      page: nil,
      state: .unavailable(reason: failure),
      sourceFailure: failure)
  }

  private func loadCache() -> LastGoodCache? {
    guard let cacheURL, let externalReader,
      let data = try? Data(contentsOf: cacheURL),
      let cache = try? JSONDecoder().decode(LastGoodCache.self, from: data),
      cache.sourceKey == externalReader.sourceKey
    else { return nil }
    return cache
  }

  private func saveCache(
    pages incomingPages: [TatwoCuratedPageSummaryV1],
    mergingContents incomingContents: [String: String],
    replacingPageSet: Bool = false
  ) {
    guard let cacheURL, let externalReader else { return }
    var cache = loadCache() ?? LastGoodCache(
      sourceKey: externalReader.sourceKey,
      savedAt: now(),
      pages: [],
      contents: [:])
    var pagesBySlug = replacingPageSet
      ? [:]
      : Dictionary(uniqueKeysWithValues: cache.pages.map { ($0.slug, $0) })
    if replacingPageSet {
      cache.contents = [:]
    }
    for page in incomingPages { pagesBySlug[page.slug] = page }
    for (slug, content) in incomingContents { cache.contents[slug] = content }
    cache.pages = Array(pagesBySlug.values).sorted {
      $0.slug.localizedStandardCompare($1.slug) == .orderedAscending
    }
    cache.savedAt = now()

    guard let data = try? JSONEncoder().encode(cache) else { return }
    do {
      try fileManager.createDirectory(
        at: cacheURL.deletingLastPathComponent(),
        withIntermediateDirectories: true)
      try data.write(to: cacheURL, options: .atomic)
    } catch {
      // Cache failure never changes the fresh source result.
    }
  }
}
