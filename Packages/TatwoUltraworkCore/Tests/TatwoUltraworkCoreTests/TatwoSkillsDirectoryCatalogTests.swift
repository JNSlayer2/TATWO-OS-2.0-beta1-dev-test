import XCTest

@testable import TatwoUltraworkCore

final class TatwoSkillsDirectoryCatalogTests: XCTestCase {
  private var fixtureRoot: URL!

  override func setUpWithError() throws {
    fixtureRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("tatwo-skills-catalog-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
    // temporaryDirectory 是 /var → /private/var 的 symlink；取 canonical path 讓 path 斷言穩定。
    if let canonical = try fixtureRoot.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath {
      fixtureRoot = URL(fileURLWithPath: canonical, isDirectory: true)
    }

    // 案例 1：正常 skill（含 front-matter name + description）
    try makeSkill(
      directory: "web-check",
      manifest: """
      ---
      name: Web Check
      description: 前端健檢工具；本地掃描不上傳程式碼。
      allowed-tools: Bash
      ---

      # Web Check

      詳細說明本文。
      """
    )

    // 案例 2：無 SKILL.md 的目錄
    try FileManager.default.createDirectory(
      at: fixtureRoot.appendingPathComponent("bare-dir", isDirectory: true),
      withIntermediateDirectories: true
    )

    // 案例 3：壞 front-matter（沒有關閉的 ---）
    try makeSkill(
      directory: "broken-fm",
      manifest: """
      ---
      name: Broken Skill
      description: 這段 front-matter 沒有關閉

      # 內文
      """
    )

    // 干擾項：root 下的普通檔案應被忽略
    try Data("not a skill".utf8).write(to: fixtureRoot.appendingPathComponent("stray.txt"))
  }

  override func tearDownWithError() throws {
    if let fixtureRoot {
      try? FileManager.default.removeItem(at: fixtureRoot)
    }
    fixtureRoot = nil
  }

  private func makeSkill(directory: String, manifest: String) throws {
    let dir = fixtureRoot.appendingPathComponent(directory, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data(manifest.utf8).write(to: dir.appendingPathComponent("SKILL.md"))
  }

  func testScanNormalSkillParsesFrontMatterNameAndSummary() {
    let catalog = TatwoSkillsDirectoryCatalog(rootURL: fixtureRoot)
    let entries = catalog.scan(registeredPaths: [])
    let entry = entries.first { $0.id == "web-check" }
    XCTAssertNotNil(entry)
    XCTAssertEqual(entry?.name, "Web Check")
    XCTAssertEqual(entry?.summary, "前端健檢工具；本地掃描不上傳程式碼。")
    XCTAssertEqual(entry?.hasManifest, true)
    XCTAssertEqual(entry?.isRegistered, false)
    XCTAssertEqual(entry?.path, fixtureRoot.appendingPathComponent("web-check").path)
    XCTAssertNil(entry?.snapshotSourcePath)
    XCTAssertFalse(entry?.usesLinkedSnapshotSource == true)
  }

  func testScanDirectoryWithoutManifestFallsBackToDirectoryName() {
    let catalog = TatwoSkillsDirectoryCatalog(rootURL: fixtureRoot)
    let entries = catalog.scan(registeredPaths: [])
    let entry = entries.first { $0.id == "bare-dir" }
    XCTAssertNotNil(entry)
    XCTAssertEqual(entry?.name, "bare-dir")
    XCTAssertNil(entry?.summary)
    XCTAssertEqual(entry?.hasManifest, false)
  }

  func testScanBrokenFrontMatterFallsBackToDirectoryNameButKeepsManifestFlag() {
    let catalog = TatwoSkillsDirectoryCatalog(rootURL: fixtureRoot)
    let entries = catalog.scan(registeredPaths: [])
    let entry = entries.first { $0.id == "broken-fm" }
    XCTAssertNotNil(entry)
    XCTAssertEqual(entry?.name, "broken-fm")
    XCTAssertNil(entry?.summary)
    XCTAssertEqual(entry?.hasManifest, true)
  }

  func testScanMissingRootReturnsEmptyWithoutThrowing() {
    let missing = fixtureRoot.appendingPathComponent("does-not-exist", isDirectory: true)
    let catalog = TatwoSkillsDirectoryCatalog(rootURL: missing)
    XCTAssertEqual(catalog.scan(registeredPaths: ["/anything"]), [])
    XCTAssertFalse(catalog.rootIsAvailable())
  }

  func testScanSortsByNameAscendingAndSkipsPlainFiles() {
    let catalog = TatwoSkillsDirectoryCatalog(rootURL: fixtureRoot)
    let entries = catalog.scan(registeredPaths: [])
    XCTAssertEqual(entries.count, 3)
    XCTAssertFalse(entries.contains { $0.id == "stray.txt" })
    let names = entries.map(\.name)
    XCTAssertEqual(
      names,
      names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    )
  }

  func testScanIncludesTopLevelDirectorySymlinkUsingPortableLinkIdentity() throws {
    let target = fixtureRoot.appendingPathComponent(".linked-target", isDirectory: true)
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    try Data(
      """
      ---
      name: Linked Skill
      description: Canonical skill exposed through a top-level symlink.
      ---
      """.utf8
    ).write(to: target.appendingPathComponent("SKILL.md"))
    let link = fixtureRoot.appendingPathComponent("linked-skill", isDirectory: true)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

    let entries = TatwoSkillsDirectoryCatalog(rootURL: fixtureRoot)
      .scan(registeredPaths: [link.path])
    let entry = try XCTUnwrap(entries.first { $0.id == "linked-skill" })

    XCTAssertEqual(entry.name, "Linked Skill")
    XCTAssertEqual(entry.path, link.path)
    XCTAssertEqual(
      entry.snapshotSourcePath,
      target.resolvingSymlinksInPath().standardizedFileURL.path
    )
    XCTAssertEqual(
      entry.snapshotSourceURL.path,
      target.resolvingSymlinksInPath().standardizedFileURL.path
    )
    XCTAssertTrue(entry.usesLinkedSnapshotSource)
    XCTAssertTrue(entry.hasManifest)
    XCTAssertTrue(entry.isRegistered)
  }

  func testScannedTopLevelDirectorySymlinkCanCreateImmutableSnapshot() throws {
    let target = fixtureRoot.appendingPathComponent(".snapshot-target", isDirectory: true)
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    try Data(
      """
      ---
      name: Linked Snapshot Skill
      description: Snapshot source resolves only the governed top-level link.
      ---
      """.utf8
    ).write(to: target.appendingPathComponent("SKILL.md"))
    let link = fixtureRoot.appendingPathComponent("linked-snapshot", isDirectory: true)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

    let entry = try XCTUnwrap(
      TatwoSkillsDirectoryCatalog(rootURL: fixtureRoot)
        .scan(registeredPaths: [])
        .first { $0.id == "linked-snapshot" }
    )
    let storeRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("tatwo-linked-snapshot-store-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: storeRoot) }

    let revision = try TatwoSkilletRepositoryStore(rootURL: storeRoot)
      .snapshotCanonicalSkillDirectory(
        repositoryID: entry.id,
        displayName: entry.name,
        summary: entry.summary ?? "",
        sourceDirectory: entry.snapshotSourceURL,
        channel: .staging
      )

    XCTAssertEqual(revision.repositoryID, "linked-snapshot")
    XCTAssertTrue(
      try TatwoSkilletRepositoryStore(rootURL: storeRoot)
        .verifyRevision(repositoryID: entry.id, revisionID: revision.id)
    )
  }

  func testLegacyCatalogEntryDecodesWithoutSnapshotSourcePath() throws {
    let data = Data(
      """
      {
        "id": "legacy",
        "name": "Legacy",
        "summary": null,
        "path": "/tmp/legacy",
        "hasManifest": true,
        "isRegistered": false
      }
      """.utf8
    )

    let entry = try JSONDecoder().decode(TatwoSkillsDirectoryEntryV1.self, from: data)

    XCTAssertNil(entry.snapshotSourcePath)
    XCTAssertFalse(entry.usesLinkedSnapshotSource)
    XCTAssertEqual(entry.snapshotSourceURL.path, "/tmp/legacy")
  }

  func testScanSkipsBrokenSymlinkAndSymlinkToPlainFile() throws {
    let broken = fixtureRoot.appendingPathComponent("broken-link", isDirectory: true)
    try FileManager.default.createSymbolicLink(
      at: broken,
      withDestinationURL: fixtureRoot.appendingPathComponent("missing-target")
    )
    let fileTarget = fixtureRoot.appendingPathComponent(".linked-file")
    try Data("not a directory".utf8).write(to: fileTarget)
    let fileLink = fixtureRoot.appendingPathComponent("file-link", isDirectory: true)
    try FileManager.default.createSymbolicLink(at: fileLink, withDestinationURL: fileTarget)

    let entries = TatwoSkillsDirectoryCatalog(rootURL: fixtureRoot)
      .scan(registeredPaths: [])

    XCTAssertFalse(entries.contains { $0.id == "broken-link" })
    XCTAssertFalse(entries.contains { $0.id == "file-link" })
  }

  func testScanMarksRegisteredPathsIncludingTrailingSlashVariant() {
    let catalog = TatwoSkillsDirectoryCatalog(rootURL: fixtureRoot)
    let registered: Set<String> = [
      fixtureRoot.appendingPathComponent("web-check").path + "/"
    ]
    let entries = catalog.scan(registeredPaths: registered)
    XCTAssertEqual(entries.first { $0.id == "web-check" }?.isRegistered, true)
    XCTAssertEqual(entries.first { $0.id == "bare-dir" }?.isRegistered, false)
  }

  func testLoadDetailReturnsFullManifestAndNilForMissingOrUnsafeIDs() {
    let catalog = TatwoSkillsDirectoryCatalog(rootURL: fixtureRoot)
    let detail = catalog.loadDetail(id: "web-check")
    XCTAssertNotNil(detail)
    XCTAssertTrue(detail?.contains("詳細說明本文。") == true)
    XCTAssertNil(catalog.loadDetail(id: "bare-dir"))
    XCTAssertNil(catalog.loadDetail(id: "no-such-skill"))
    XCTAssertNil(catalog.loadDetail(id: "../web-check"))
    XCTAssertNil(catalog.loadDetail(id: ""))
  }

  func testLoadDetailTruncatesOversizedManifestAt64KB() throws {
    let body = String(repeating: "A", count: TatwoSkillsDirectoryCatalog.detailByteLimit + 4096)
    try makeSkill(directory: "huge", manifest: body)
    let catalog = TatwoSkillsDirectoryCatalog(rootURL: fixtureRoot)
    let detail = try XCTUnwrap(catalog.loadDetail(id: "huge"))
    XCTAssertTrue(detail.contains("已截斷"))
    XCTAssertLessThan(detail.utf8.count, body.utf8.count)
  }

  func testDefaultRootHonorsEnvironmentOverrideAndLocalFallback() {
    let overridden = TatwoSkillsDirectoryCatalog.defaultRoot(
      environment: ["TATWO_SKILLS_CANONICAL_DIR": "/tmp/custom-skills"]
    )
    XCTAssertEqual(overridden.path, "/tmp/custom-skills")

    let blankOverride = TatwoSkillsDirectoryCatalog.defaultRoot(
      environment: ["TATWO_SKILLS_CANONICAL_DIR": "   "]
    )
    XCTAssertEqual(
      blankOverride.path,
      TatwoRuntimeLayout.applicationSupportRoot(
        environment: ["TATWO_SKILLS_CANONICAL_DIR": "   "]
      ).appendingPathComponent("skills").path
    )

    let fallback = TatwoSkillsDirectoryCatalog.defaultRoot(environment: [:])
    XCTAssertEqual(
      fallback.path,
      TatwoRuntimeLayout.applicationSupportRoot(environment: [:])
        .appendingPathComponent("skills").path
    )
  }
}
