import Foundation
import XCTest

@testable import TatwoUltraworkCore

final class TatwoCuratedMemoryReaderV1Tests: XCTestCase {
  private let fileManager = FileManager.default

  func testUnconfiguredRootIsGracefulEmptyRatherThanUnavailable() throws {
    let supportBase = try makeDirectory(named: "support-base")
    defer { try? fileManager.removeItem(at: supportBase) }

    let reader = TatwoCuratedMemoryReaderV1(
      environment: [:],
      applicationSupportBase: supportBase)

    XCTAssertNil(reader.rootURL)
    XCTAssertEqual(
      reader.list(),
      TatwoCuratedPageListV1(
        pages: [],
        state: .gracefulEmpty))
    XCTAssertEqual(reader.page("anything").state, .gracefulEmpty)
  }

  func testF10EnvironmentOSRootPrecedesLocalOSRootAndLocalGBrainRootOverridesDerivedRoot()
    throws
  {
    let supportBase = try makeDirectory(named: "support-f10-priority")
    defer { try? fileManager.removeItem(at: supportBase) }
    let appSupport = supportBase
      .appendingPathComponent(TatwoRuntimeLayout.applicationSupportDirectoryName, isDirectory: true)
    try fileManager.createDirectory(at: appSupport, withIntermediateDirectories: true)
    let localFile = appSupport.appendingPathComponent(
      TatwoCuratedMemoryReaderV1.localRootFileName)
    let environmentOSRoot = supportBase.appendingPathComponent("environment-os-root")
    let localOSRoot = supportBase.appendingPathComponent("local-os-root")
    let localGBrainOverride = supportBase.appendingPathComponent("local-gbrain-override")

    try """
      {"osRoot":"\(localOSRoot.path)"}
      """.write(to: localFile, atomically: true, encoding: .utf8)
    let environmentWinner = TatwoCuratedMemoryReaderV1(
      environment: [
        TatwoCuratedMemoryReaderV1.osRootEnvironmentKey: environmentOSRoot.path
      ],
      applicationSupportBase: supportBase)
    XCTAssertEqual(
      environmentWinner.rootURL,
      environmentOSRoot.appendingPathComponent("gbrain", isDirectory: true)
        .standardizedFileURL)

    try """
      {"osRoot":"\(localOSRoot.path)","gbrainRoot":"\(localGBrainOverride.path)"}
      """.write(to: localFile, atomically: true, encoding: .utf8)
    let explicitGBrainOverride = TatwoCuratedMemoryReaderV1(
      environment: [
        TatwoCuratedMemoryReaderV1.osRootEnvironmentKey: environmentOSRoot.path
      ],
      applicationSupportBase: supportBase)
    XCTAssertEqual(
      explicitGBrainOverride.rootURL,
      localGBrainOverride.standardizedFileURL)
  }

  func testF10AppSupportLocalFileSuppliesRootWhenEnvironmentIsUnset() throws {
    let supportBase = try makeDirectory(named: "support-f10-fallback")
    defer { try? fileManager.removeItem(at: supportBase) }
    let appSupport = supportBase
      .appendingPathComponent(TatwoRuntimeLayout.applicationSupportDirectoryName, isDirectory: true)
    try fileManager.createDirectory(at: appSupport, withIntermediateDirectories: true)
    let localOSRoot = supportBase.appendingPathComponent("local-only-os-root")
    try """
      {"osRoot":"\(localOSRoot.path)"}
      """.write(
        to: appSupport.appendingPathComponent(
          TatwoCuratedMemoryReaderV1.localRootFileName),
        atomically: true,
        encoding: .utf8)

    let reader = TatwoCuratedMemoryReaderV1(
      environment: [:],
      applicationSupportBase: supportBase)

    XCTAssertEqual(
      reader.rootURL,
      localOSRoot.appendingPathComponent("gbrain", isDirectory: true)
        .standardizedFileURL)
  }

  func testUnavailableVolumePreservesClassifiedReason() {
    let root = URL(
      fileURLWithPath: "/tmp/curated-denied-\(UUID().uuidString)",
      isDirectory: true)
    let externalReader = ExternalVolumeReader(
      rootURL: root,
      fileSystem: FailingFileSystem(errorCode: EACCES))
    let reader = TatwoCuratedMemoryReaderV1(
      rootURL: root,
      externalReader: externalReader)

    let result = reader.list()

    XCTAssertEqual(result.pages, [])
    XCTAssertEqual(result.state, .unavailable(reason: .permissionDenied))
    XCTAssertEqual(result.sourceFailure, .permissionDenied)
  }

  func testReadsCuratedSummaryAndFullPage() throws {
    let fixture = try makeFixture()
    defer { try? fileManager.removeItem(at: fixture.root) }
    let updatedAt = try XCTUnwrap(
      ISO8601DateFormatter().date(from: "2026-07-29T08:15:30Z"))
    let content = """
      ---
      title: "Admin email truth"
      updated_at: 2026-07-29T08:15:30Z
      tags: [operations, identity, operations]
      layer: curated
      ---
      # Ignored because front matter supplies title

      The production editor is the adjudicated account.
      """
    try content.write(
      to: fixture.curated.appendingPathComponent("admin-email.md"),
      atomically: true,
      encoding: .utf8)

    let reader = TatwoCuratedMemoryReaderV1(rootURL: fixture.root)
    let list = reader.list()
    let summary = try XCTUnwrap(list.pages.first)

    XCTAssertEqual(list.state, .fresh)
    XCTAssertEqual(list.pages.count, 1)
    XCTAssertEqual(summary.slug, "admin-email")
    XCTAssertEqual(summary.title, "Admin email truth")
    XCTAssertEqual(summary.updatedAt, updatedAt)
    XCTAssertEqual(summary.tags, ["identity", "operations"])
    XCTAssertEqual(summary.excerpt, "The production editor is the adjudicated account.")

    let detail = reader.page("admin-email")
    XCTAssertEqual(detail.state, .fresh)
    XCTAssertEqual(detail.page?.summary, summary)
    XCTAssertEqual(detail.page?.content, content)
  }

  func testLastGoodCacheIsExplicitlyStaleWhenSourceBecomesUnavailable() throws {
    let fixture = try makeFixture()
    defer { try? fileManager.removeItem(at: fixture.root) }
    let cacheURL = fixture.root.appendingPathComponent("cache/last-good.json")
    let savedAt = Date(timeIntervalSince1970: 1_775_000_000)
    let content = """
      ---
      title: Cached truth
      tags: [cache]
      ---
      This is the last known curated value.
      """
    try content.write(
      to: fixture.curated.appendingPathComponent("cached.md"),
      atomically: true,
      encoding: .utf8)

    let freshReader = TatwoCuratedMemoryReaderV1(
      rootURL: fixture.root,
      cacheURL: cacheURL,
      now: { savedAt })
    XCTAssertEqual(freshReader.list().state, .fresh)

    let failedExternalReader = ExternalVolumeReader(
      rootURL: fixture.root,
      fileSystem: FailingFileSystem(errorCode: EACCES))
    let staleReader = TatwoCuratedMemoryReaderV1(
      rootURL: fixture.root,
      cacheURL: cacheURL,
      externalReader: failedExternalReader)

    let staleList = staleReader.list()
    XCTAssertEqual(staleList.state, .stale(since: savedAt))
    XCTAssertEqual(staleList.sourceFailure, .permissionDenied)
    XCTAssertEqual(staleList.pages.map(\.slug), ["cached"])

    let stalePage = staleReader.page("cached")
    XCTAssertEqual(stalePage.state, .stale(since: savedAt))
    XCTAssertEqual(stalePage.sourceFailure, .permissionDenied)
    XCTAssertEqual(stalePage.page?.content, content)
  }

  func testRawLayerIsNeverReadAndCannotShadowCuratedPage() throws {
    let fixture = try makeFixture()
    defer { try? fileManager.removeItem(at: fixture.root) }
    let raw = fixture.root.appendingPathComponent("raw", isDirectory: true)
    let truth = fixture.root.appendingPathComponent("truth", isDirectory: true)
    try fileManager.createDirectory(at: raw, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: truth, withIntermediateDirectories: true)
    try "# Curated\nVisible curated body.".write(
      to: fixture.curated.appendingPathComponent("shared.md"),
      atomically: true,
      encoding: .utf8)
    try "# Raw\nMUST NOT BE READ".write(
      to: raw.appendingPathComponent("shared.md"),
      atomically: true,
      encoding: .utf8)
    try "# Truth\nMUST NOT BE READ".write(
      to: truth.appendingPathComponent("shared.md"),
      atomically: true,
      encoding: .utf8)

    let recordingFileSystem = RecordingFileSystem()
    let externalReader = ExternalVolumeReader(
      rootURL: fixture.root,
      fileSystem: recordingFileSystem)
    let reader = TatwoCuratedMemoryReaderV1(
      rootURL: fixture.root,
      externalReader: externalReader)

    let list = reader.list()
    let detail = reader.page("shared")

    XCTAssertEqual(list.pages.map(\.slug), ["shared"])
    XCTAssertEqual(detail.page?.content, "# Curated\nVisible curated body.")
    XCTAssertFalse(
      recordingFileSystem.accessedPaths.contains(where: {
        $0 == raw.path || $0.hasPrefix(raw.path + "/")
      }),
      "The App projection must never inspect, list, or read the raw layer.")
    XCTAssertFalse(
      recordingFileSystem.accessedPaths.contains(where: {
        $0 == truth.path || $0.hasPrefix(truth.path + "/")
      }),
      "The curated-only App projection must never inspect, list, or read the truth sibling.")
  }

  func testSlugTraversalAndRawPathAreRejectedBeforeFileSystemAccess() {
    let root = URL(fileURLWithPath: "/tmp/curated-slug-\(UUID().uuidString)")
    let recordingFileSystem = RecordingFileSystem()
    let externalReader = ExternalVolumeReader(
      rootURL: root,
      fileSystem: recordingFileSystem)
    let reader = TatwoCuratedMemoryReaderV1(
      rootURL: root,
      externalReader: externalReader)

    for slug in ["../raw/secret", "raw/secret", "/absolute", "page.md", "..", #"raw\secret"#] {
      let result = reader.page(slug)
      XCTAssertEqual(result.state, .unavailable(reason: .ioError), slug)
      XCTAssertNil(result.page, slug)
    }
    XCTAssertTrue(
      recordingFileSystem.accessedPaths.isEmpty,
      "Invalid slugs must fail before any source I/O.")
  }

  func testCuratedDirectorySymlinkToRawIsUnavailableAndTargetIsNotRead() throws {
    let root = try makeDirectory(named: "gbrain-symlink")
    defer { try? fileManager.removeItem(at: root) }
    let raw = root.appendingPathComponent("raw", isDirectory: true)
    try fileManager.createDirectory(at: raw, withIntermediateDirectories: true)
    try "# Raw\nMUST NOT BE READ".write(
      to: raw.appendingPathComponent("secret.md"),
      atomically: true,
      encoding: .utf8)
    try fileManager.createSymbolicLink(
      at: root.appendingPathComponent("curated", isDirectory: true),
      withDestinationURL: raw)

    let recordingFileSystem = RecordingFileSystem()
    let externalReader = ExternalVolumeReader(
      rootURL: root,
      fileSystem: recordingFileSystem)
    let reader = TatwoCuratedMemoryReaderV1(
      rootURL: root,
      externalReader: externalReader)

    let list = reader.list()
    let detail = reader.page("secret")

    XCTAssertEqual(list.state, .unavailable(reason: .ioError))
    XCTAssertEqual(list.pages, [])
    XCTAssertEqual(detail.state, .unavailable(reason: .ioError))
    XCTAssertNil(detail.page)
    XCTAssertFalse(
      recordingFileSystem.accessedPaths.contains(where: {
        $0 == raw.path || $0.hasPrefix(raw.path + "/")
      }),
      "A curated-directory symlink must be rejected without reading its raw target.")
  }

  func testCacheFromDifferentRootIsNeverReturnedAsStale() throws {
    let first = try makeFixture()
    let secondRoot = try makeDirectory(named: "second-gbrain")
    let cacheURL = first.root.appendingPathComponent("cache/shared.json")
    defer {
      try? fileManager.removeItem(at: first.root)
      try? fileManager.removeItem(at: secondRoot)
    }
    try "# First root\nFirst root content.".write(
      to: first.curated.appendingPathComponent("first.md"),
      atomically: true,
      encoding: .utf8)
    XCTAssertEqual(
      TatwoCuratedMemoryReaderV1(rootURL: first.root, cacheURL: cacheURL)
        .list().pages.map(\.slug),
      ["first"])

    let failedSecondSource = ExternalVolumeReader(
      rootURL: secondRoot,
      fileSystem: FailingFileSystem(errorCode: EACCES))
    let secondReader = TatwoCuratedMemoryReaderV1(
      rootURL: secondRoot,
      cacheURL: cacheURL,
      externalReader: failedSecondSource)

    let list = secondReader.list()
    let page = secondReader.page("first")

    XCTAssertEqual(list.state, .unavailable(reason: .permissionDenied))
    XCTAssertEqual(list.pages, [])
    XCTAssertEqual(page.state, .unavailable(reason: .permissionDenied))
    XCTAssertNil(page.page)
  }

  func testPartialRefreshFailureKeepsCompletePriorCacheAndIsNotFresh() throws {
    let fixture = try makeFixture()
    defer { try? fileManager.removeItem(at: fixture.root) }
    let cacheURL = fixture.root.appendingPathComponent("cache/complete.json")
    let firstSavedAt = Date(timeIntervalSince1970: 1_774_000_000)
    let goodURL = fixture.curated.appendingPathComponent("good.md")
    let otherURL = fixture.curated.appendingPathComponent("other.md")
    try "# Good\nOriginal good value.".write(
      to: goodURL, atomically: true, encoding: .utf8)
    try "# Other\nOriginal other value.".write(
      to: otherURL, atomically: true, encoding: .utf8)

    let initial = TatwoCuratedMemoryReaderV1(
      rootURL: fixture.root,
      cacheURL: cacheURL,
      now: { firstSavedAt }).list()
    XCTAssertEqual(initial.state, .fresh)
    XCTAssertEqual(Set(initial.pages.map(\.slug)), Set(["good", "other"]))

    try "# Good\nChanged value.".write(
      to: goodURL, atomically: true, encoding: .utf8)
    try String(repeating: "x", count: 128).write(
      to: otherURL, atomically: true, encoding: .utf8)
    let partial = TatwoCuratedMemoryReaderV1(
      rootURL: fixture.root,
      cacheURL: cacheURL,
      maximumPageBytes: 32).list()

    XCTAssertEqual(partial.state, .stale(since: firstSavedAt))
    XCTAssertEqual(Set(partial.pages.map(\.slug)), Set(["good", "other"]))

    let failedSource = ExternalVolumeReader(
      rootURL: fixture.root,
      fileSystem: FailingFileSystem(errorCode: EACCES))
    let cachedGood = TatwoCuratedMemoryReaderV1(
      rootURL: fixture.root,
      cacheURL: cacheURL,
      externalReader: failedSource).page("good")
    XCTAssertEqual(cachedGood.state, .stale(since: firstSavedAt))
    XCTAssertEqual(cachedGood.page?.content, "# Good\nOriginal good value.")
  }

  private func makeFixture() throws -> (root: URL, curated: URL) {
    let root = try makeDirectory(named: "gbrain")
    let curated = root.appendingPathComponent("curated", isDirectory: true)
    try fileManager.createDirectory(at: curated, withIntermediateDirectories: true)
    return (root, curated)
  }

  private func makeDirectory(named name: String) throws -> URL {
    let url = fileManager.temporaryDirectory
      .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}

private struct FailingFileSystem: ExternalVolumeFileSystem {
  let errorCode: Int32

  func inspect(_ url: URL) throws -> ExternalVolumeFileInfo {
    throw error()
  }

  func listDirectory(
    _ url: URL,
    maximumEntries: Int
  ) throws -> [ExternalVolumeDirectoryEntry] {
    throw error()
  }

  func readFile(_ url: URL, maximumBytes: Int) throws -> Data {
    throw error()
  }

  private func error() -> NSError {
    NSError(domain: NSPOSIXErrorDomain, code: Int(errorCode))
  }
}

private final class RecordingFileSystem: @unchecked Sendable, ExternalVolumeFileSystem {
  private let underlying = FileManagerExternalVolumeFileSystem()
  private let lock = NSLock()
  private var paths: [String] = []

  var accessedPaths: [String] {
    lock.withLock { paths }
  }

  func inspect(_ url: URL) throws -> ExternalVolumeFileInfo {
    record(url)
    return try underlying.inspect(url)
  }

  func listDirectory(
    _ url: URL,
    maximumEntries: Int
  ) throws -> [ExternalVolumeDirectoryEntry] {
    record(url)
    return try underlying.listDirectory(url, maximumEntries: maximumEntries)
  }

  func readFile(_ url: URL, maximumBytes: Int) throws -> Data {
    record(url)
    return try underlying.readFile(url, maximumBytes: maximumBytes)
  }

  private func record(_ url: URL) {
    lock.withLock {
      paths.append(url.standardizedFileURL.path)
    }
  }
}
