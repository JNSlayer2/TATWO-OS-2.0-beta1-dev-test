import CryptoKit
import Foundation
import XCTest

@testable import TatwoUltraworkCore

final class TatwoLocalInternalInstallAnchorTests: XCTestCase {
  func testFileStoreWritesExact0600AndLoadsFirstGeneration() throws {
    let root = temporaryDirectory("first")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = TatwoLocalInternalInstallAnchorFileStore(
      installerRootURL: root)
    let anchor = makeAnchor(generation: 1, previousDigest: nil)

    try store.save(anchor)

    XCTAssertEqual(try store.load(), anchor)
    let attributes = try FileManager.default.attributesOfItem(
      atPath: store.url.path)
    XCTAssertEqual(
      (attributes[.posixPermissions] as? NSNumber)?.uint16Value,
      0o600)
  }

  func testReplacementRequiresNextGenerationAndExactPreviousBytesDigest()
    throws
  {
    let root = temporaryDirectory("replacement")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = TatwoLocalInternalInstallAnchorFileStore(
      installerRootURL: root)
    let first = makeAnchor(generation: 1, previousDigest: nil)
    try store.save(first)
    let previousData = try Data(contentsOf: store.url)
    let previousDigest = sha256Hex(previousData)
    let second = makeAnchor(
      generation: 2,
      previousDigest: previousDigest,
      candidateID: String(repeating: "b", count: 64))

    try store.save(second)

    XCTAssertEqual(try store.load(), second)

    let invalid = makeAnchor(
      generation: 3,
      previousDigest: String(repeating: "0", count: 64),
      candidateID: String(repeating: "c", count: 64))
    XCTAssertThrowsError(try store.save(invalid)) { error in
      guard case TatwoProductionLayoutError
        .localInternalInstallAnchorRejected = error
      else {
        return XCTFail("unexpected error: \(error)")
      }
    }
  }

  func testLoadRejectsSymlinkAndNon0600Anchor() throws {
    let root = temporaryDirectory("unsafe-file")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = TatwoLocalInternalInstallAnchorFileStore(
      installerRootURL: root)
    let external = root.appendingPathComponent("external.json")
    let data = try JSONEncoder().encode(
      makeAnchor(generation: 1, previousDigest: nil))
    try data.write(to: external)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: external.path)
    try FileManager.default.createSymbolicLink(
      at: store.url,
      withDestinationURL: external)

    XCTAssertThrowsError(try store.load())

    try FileManager.default.removeItem(at: store.url)
    try data.write(to: store.url)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o644],
      ofItemAtPath: store.url.path)
    XCTAssertThrowsError(try store.load())
  }

  func testLoadRejectsSymlinkInstallerRootPathEscape() throws {
    let base = temporaryDirectory("unsafe-root")
    defer { try? FileManager.default.removeItem(at: base) }
    let actualRoot = base.appendingPathComponent("actual", isDirectory: true)
    let linkedRoot = base.appendingPathComponent("linked", isDirectory: true)
    try FileManager.default.createDirectory(
      at: actualRoot,
      withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: linkedRoot,
      withDestinationURL: actualRoot)
    let store = TatwoLocalInternalInstallAnchorFileStore(
      installerRootURL: linkedRoot)

    XCTAssertThrowsError(
      try store.save(makeAnchor(generation: 1, previousDigest: nil)))
  }

  private func makeAnchor(
    generation: UInt64,
    previousDigest: String?,
    candidateID: String = String(repeating: "a", count: 64)
  ) -> TatwoLocalInternalInstallAnchorV1 {
    let receiptID = String(repeating: "d", count: 64)
    return TatwoLocalInternalInstallAnchorV1(
      candidateID: candidateID,
      receiptID: receiptID,
      receiptFilename: "local-app-install-\(receiptID).txt",
      receiptSHA256: String(repeating: "e", count: 64),
      pointerSHA256: String(repeating: "f", count: 64),
      canonicalAppPath: "/Applications/Tatwo Ultrawork.app",
      canonicalStateRoot:
        "/Users/test/Library/Application Support/Tatwo Ultrawork/state",
      deviceID: "device-test",
      installGeneration: generation,
      previousAnchorSHA256: previousDigest,
      createdAt: "2026-08-05T12:00:00Z")
  }

  private func temporaryDirectory(_ suffix: String) -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "tatwo-local-install-anchor-\(suffix)-\(UUID().uuidString)",
      isDirectory: true)
    try! FileManager.default.createDirectory(
      at: url,
      withIntermediateDirectories: true)
    return url
  }

  private func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data)
      .map { String(format: "%02x", $0) }
      .joined()
  }
}
