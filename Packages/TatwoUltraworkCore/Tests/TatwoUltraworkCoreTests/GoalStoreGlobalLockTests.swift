import Foundation
import XCTest

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

@testable import TatwoUltraworkCore

final class GoalStoreGlobalLockTests: XCTestCase {
  func testCanonicalExactArtifactPathsAreFixedUnderStandardizedGoalStoreRoot() {
    let raw = URL(fileURLWithPath: "/tmp/a/../goal-store", isDirectory: true)
    let root = raw.standardizedFileURL

    XCTAssertEqual(
      TatwoGoalStoreGlobalLock.lockURL(forGoalStoreRoot: raw).path,
      root.appendingPathComponent(
        ".tatwo-goal-store.global.lock").path)
    XCTAssertEqual(
      TatwoGoalStoreGlobalLock.initializationReceiptURL(
        forGoalStoreRoot: raw).path,
      root.appendingPathComponent(
        ".tatwo-goal-store.global-lock.initialized.json").path)
  }

  func testCreateOnlyInitializerDurablyCreatesExactLockAndReceiptThenStops() throws {
    try withTemporaryGoalStoreRoot { root in
      let createdAt = Date(timeIntervalSince1970: 1_786_032_000)
      let receipt = try TatwoGoalStoreGlobalLock.initializeCreateOnly(
        goalStoreRoot: root,
        createdAt: createdAt)
      let lockURL = TatwoGoalStoreGlobalLock.lockURL(forGoalStoreRoot: root)
      let receiptURL =
        TatwoGoalStoreGlobalLock.initializationReceiptURL(
          forGoalStoreRoot: root)

      var lockStatus = stat()
      XCTAssertEqual(lstat(lockURL.path, &lockStatus), 0)
      XCTAssertEqual(lockStatus.st_mode & S_IFMT, S_IFREG)
      XCTAssertEqual(lockStatus.st_mode & 0o7777, 0o600)
      XCTAssertEqual(lockStatus.st_uid, getuid())
      XCTAssertEqual(lockStatus.st_gid, getgid())
      XCTAssertEqual(lockStatus.st_nlink, 1)
      XCTAssertEqual(lockStatus.st_size, 0)

      XCTAssertEqual(receipt.schema, "TatwoGoalStoreGlobalLockInitializationReceiptV1")
      XCTAssertEqual(receipt.canonicalGoalStoreRootPath, root.standardizedFileURL.path)
      XCTAssertEqual(receipt.lockPath, lockURL.path)
      XCTAssertEqual(receipt.receiptPath, receiptURL.path)
      XCTAssertEqual(receipt.ownerUserID, UInt32(getuid()))
      XCTAssertEqual(receipt.ownerGroupID, UInt32(getgid()))
      XCTAssertEqual(receipt.mode, 0o600)
      XCTAssertEqual(receipt.linkCount, 1)
      XCTAssertEqual(receipt.size, 0)
      XCTAssertEqual(receipt.inode, UInt64(lockStatus.st_ino))
      XCTAssertEqual(receipt.createdAt, createdAt)

      let storedBytes = try Data(contentsOf: receiptURL)
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      XCTAssertEqual(
        try decoder.decode(
          TatwoGoalStoreGlobalLockInitializationReceiptV1.self,
          from: storedBytes),
        receipt)

      let beforeLockIdentity = (lockStatus.st_dev, lockStatus.st_ino)
      XCTAssertThrowsError(
        try TatwoGoalStoreGlobalLock.initializeCreateOnly(
          goalStoreRoot: root))
      XCTAssertEqual(try Data(contentsOf: receiptURL), storedBytes)
      XCTAssertEqual(lstat(lockURL.path, &lockStatus), 0)
      XCTAssertEqual(lockStatus.st_dev, beforeLockIdentity.0)
      XCTAssertEqual(lockStatus.st_ino, beforeLockIdentity.1)
    }
  }

  func testInitializedLockRunsProtectedBody() throws {
    try withTemporaryGoalStoreRoot { root in
      _ = try TatwoGoalStoreGlobalLock.initializeCreateOnly(
        goalStoreRoot: root)
      var executed = false

      let value = try TatwoGoalStoreGlobalLock.withExclusiveLock(
        goalStoreRoot: root
      ) {
        executed = true
        return 42
      }

      XCTAssertTrue(executed)
      XCTAssertEqual(value, 42)
    }
  }

  func testMissingLockFailsClosedWithoutCreatingArtifacts() throws {
    try withTemporaryGoalStoreRoot { root in
      let lockURL = TatwoGoalStoreGlobalLock.lockURL(forGoalStoreRoot: root)
      let receiptURL =
        TatwoGoalStoreGlobalLock.initializationReceiptURL(
          forGoalStoreRoot: root)
      var executed = false

      XCTAssertThrowsError(
        try TatwoGoalStoreGlobalLock.withExclusiveLock(
          goalStoreRoot: root
        ) {
          executed = true
        }) { error in
          XCTAssertEqual(
            error as? TatwoGoalStoreGlobalLockError,
            .artifactMissing(path: lockURL.path))
        }
      XCTAssertFalse(executed)
      XCTAssertFalse(FileManager.default.fileExists(atPath: lockURL.path))
      XCTAssertFalse(FileManager.default.fileExists(atPath: receiptURL.path))
    }
  }

  func testLockOnlyPartialInitializationRemainsVisibleAndFailsClosed() throws {
    try withTemporaryGoalStoreRoot { root in
      let lockURL = TatwoGoalStoreGlobalLock.lockURL(forGoalStoreRoot: root)
      XCTAssertTrue(
        FileManager.default.createFile(
          atPath: lockURL.path,
          contents: Data(),
          attributes: [.posixPermissions: 0o600]))
      var executed = false

      XCTAssertThrowsError(
        try TatwoGoalStoreGlobalLock.withExclusiveLock(
          goalStoreRoot: root
        ) {
          executed = true
        })
      XCTAssertFalse(executed)
      XCTAssertThrowsError(
        try TatwoGoalStoreGlobalLock.initializeCreateOnly(
          goalStoreRoot: root))
      XCTAssertTrue(FileManager.default.fileExists(atPath: lockURL.path))
      XCTAssertFalse(
        FileManager.default.fileExists(
          atPath: TatwoGoalStoreGlobalLock.initializationReceiptURL(
            forGoalStoreRoot: root).path))
    }
  }

  func testReceiptCreateFailureLeavesExplicitPartialInitialization() throws {
    try withTemporaryGoalStoreRoot { root in
      let lockURL = TatwoGoalStoreGlobalLock.lockURL(forGoalStoreRoot: root)
      let receiptURL =
        TatwoGoalStoreGlobalLock.initializationReceiptURL(
          forGoalStoreRoot: root)
      let hooks = TatwoGoalStoreGlobalLockHooks(
        flockOperation: { flock($0, $1) },
        errnoProvider: { errno },
        afterLockOpen: {},
        afterLockDurable: {
          XCTAssertTrue(
            FileManager.default.createFile(
              atPath: receiptURL.path,
              contents: Data("occupied".utf8),
              attributes: [.posixPermissions: 0o600]))
        })

      XCTAssertThrowsError(
        try TatwoGoalStoreGlobalLock.initializeCreateOnly(
          goalStoreRoot: root,
          createdAt: Date(),
          hooks: hooks))

      XCTAssertTrue(FileManager.default.fileExists(atPath: lockURL.path))
      XCTAssertEqual(try Data(contentsOf: lockURL), Data())
      XCTAssertEqual(try Data(contentsOf: receiptURL), Data("occupied".utf8))
      XCTAssertThrowsError(
        try TatwoGoalStoreGlobalLock.initializeCreateOnly(
          goalStoreRoot: root))
    }
  }

  func testSymlinkLockFailsClosedBeforeBody() throws {
    try withTemporaryGoalStoreRoot { root in
      let target = root.appendingPathComponent("target")
      XCTAssertTrue(
        FileManager.default.createFile(
          atPath: target.path, contents: Data()))
      let lockURL = TatwoGoalStoreGlobalLock.lockURL(forGoalStoreRoot: root)
      try FileManager.default.createSymbolicLink(
        at: lockURL,
        withDestinationURL: target)
      var executed = false

      XCTAssertThrowsError(
        try TatwoGoalStoreGlobalLock.withExclusiveLock(
          goalStoreRoot: root
        ) {
          executed = true
        })
      XCTAssertFalse(executed)
      var status = stat()
      XCTAssertEqual(lstat(lockURL.path, &status), 0)
      XCTAssertEqual(status.st_mode & S_IFMT, S_IFLNK)
    }
  }

  func testWrongTypeNonzeroSizeModeOwnerAndNlinkFailClosed() throws {
    try assertInvalidManualLock { lockURL in
      try FileManager.default.createDirectory(
        at: lockURL, withIntermediateDirectories: false)
    }
    try assertInvalidManualLock { lockURL in
      try Data("x".utf8).write(to: lockURL)
      XCTAssertEqual(chmod(lockURL.path, 0o600), 0)
    }
    try assertInvalidManualLock { lockURL in
      XCTAssertTrue(
        FileManager.default.createFile(
          atPath: lockURL.path, contents: Data()))
      XCTAssertEqual(chmod(lockURL.path, 0o644), 0)
    }
    try assertInvalidManualLock(expectedUserID: getuid() &+ 1) { lockURL in
      XCTAssertTrue(
        FileManager.default.createFile(
          atPath: lockURL.path, contents: Data()))
      XCTAssertEqual(chmod(lockURL.path, 0o600), 0)
    }
    try assertInvalidManualLock { lockURL in
      XCTAssertTrue(
        FileManager.default.createFile(
          atPath: lockURL.path, contents: Data()))
      XCTAssertEqual(chmod(lockURL.path, 0o600), 0)
      try FileManager.default.linkItem(
        at: lockURL,
        to: lockURL.deletingLastPathComponent()
          .appendingPathComponent("second-link"))
    }
  }

  func testPathVersusOpenedIdentityReplacementFailsClosed() throws {
    try withTemporaryGoalStoreRoot { root in
      _ = try TatwoGoalStoreGlobalLock.initializeCreateOnly(
        goalStoreRoot: root)
      let lockURL = TatwoGoalStoreGlobalLock.lockURL(forGoalStoreRoot: root)
      let movedURL = root.appendingPathComponent("moved-lock")
      let hooks = TatwoGoalStoreGlobalLockHooks(
        flockOperation: { flock($0, $1) },
        errnoProvider: { errno },
        afterLockOpen: {
          try FileManager.default.moveItem(at: lockURL, to: movedURL)
          XCTAssertTrue(
            FileManager.default.createFile(
              atPath: lockURL.path,
              contents: Data(),
              attributes: [.posixPermissions: 0o600]))
        },
        afterLockDurable: {})
      var executed = false

      XCTAssertThrowsError(
        try TatwoGoalStoreGlobalLock.withExclusiveLock(
          goalStoreRoot: root,
          expectedUserID: getuid(),
          expectedGroupID: getgid(),
          hooks: hooks
        ) {
          executed = true
        }) { error in
          XCTAssertEqual(
            error as? TatwoGoalStoreGlobalLockError,
            .artifactIdentityMismatch(path: lockURL.path))
        }
      XCTAssertFalse(executed)
    }
  }

  func testCorruptOrReplacedReceiptFailsClosedBeforeBody() throws {
    try withTemporaryGoalStoreRoot { root in
      _ = try TatwoGoalStoreGlobalLock.initializeCreateOnly(
        goalStoreRoot: root)
      let receiptURL =
        TatwoGoalStoreGlobalLock.initializationReceiptURL(
          forGoalStoreRoot: root)
      try Data("{}".utf8).write(to: receiptURL)
      XCTAssertEqual(chmod(receiptURL.path, 0o600), 0)
      var executed = false

      XCTAssertThrowsError(
        try TatwoGoalStoreGlobalLock.withExclusiveLock(
          goalStoreRoot: root
        ) {
          executed = true
        })
      XCTAssertFalse(executed)
    }

    try withTemporaryGoalStoreRoot { root in
      _ = try TatwoGoalStoreGlobalLock.initializeCreateOnly(
        goalStoreRoot: root)
      let receiptURL =
        TatwoGoalStoreGlobalLock.initializationReceiptURL(
          forGoalStoreRoot: root)
      let moved = root.appendingPathComponent("moved-receipt")
      try FileManager.default.moveItem(at: receiptURL, to: moved)
      try FileManager.default.createSymbolicLink(
        at: receiptURL,
        withDestinationURL: moved)
      var executed = false

      XCTAssertThrowsError(
        try TatwoGoalStoreGlobalLock.withExclusiveLock(
          goalStoreRoot: root
        ) {
          executed = true
        })
      XCTAssertFalse(executed)
    }
  }

  func testSemanticallyEquivalentNoncanonicalReceiptBytesFailClosed() throws {
    try withTemporaryGoalStoreRoot { root in
      _ = try TatwoGoalStoreGlobalLock.initializeCreateOnly(
        goalStoreRoot: root)
      let receiptURL =
        TatwoGoalStoreGlobalLock.initializationReceiptURL(
          forGoalStoreRoot: root)
      let object = try JSONSerialization.jsonObject(
        with: Data(contentsOf: receiptURL))
      let noncanonical = try JSONSerialization.data(
        withJSONObject: object, options: [.sortedKeys])
      try noncanonical.write(to: receiptURL)
      XCTAssertEqual(chmod(receiptURL.path, 0o600), 0)
      var executed = false

      XCTAssertThrowsError(
        try TatwoGoalStoreGlobalLock.withExclusiveLock(
          goalStoreRoot: root
        ) {
          executed = true
        }) { error in
          XCTAssertEqual(
            error as? TatwoGoalStoreGlobalLockError,
            .invalidInitializationReceipt(reason: "noncanonical_bytes"))
        }
      XCTAssertFalse(executed)
    }
  }

  func testReceiptArtifactShapeAndOpenFailuresDoNotExecuteProtectedBody() throws {
    try assertInvalidInitializedReceipt(
      expectedError: .invalidArtifact(
        path: "<receipt>",
        reason: "not_regular_file")
    ) { receiptURL in
      let moved = receiptURL.deletingLastPathComponent()
        .appendingPathComponent("original-receipt")
      try FileManager.default.moveItem(at: receiptURL, to: moved)
      try FileManager.default.createDirectory(
        at: receiptURL, withIntermediateDirectories: false)
    }

    try assertInvalidInitializedReceipt(
      expectedError: .invalidArtifact(
        path: "<receipt>",
        reason: "wrong_mode_644")
    ) { receiptURL in
      XCTAssertEqual(chmod(receiptURL.path, 0o644), 0)
    }

    try assertInvalidInitializedReceipt(
      expectedReceiptUserID: getuid() &+ 1,
      expectedError: .invalidArtifact(
        path: "<receipt>",
        reason: "wrong_owner_\(getuid())")
    ) { _ in }

    try assertInvalidInitializedReceipt(
      expectedReceiptGroupID: getgid() &+ 1,
      expectedError: .invalidArtifact(
        path: "<receipt>",
        reason: "wrong_group_\(getgid())")
    ) { _ in }

    try assertInvalidInitializedReceipt(
      expectedError: .invalidArtifact(
        path: "<receipt>",
        reason: "wrong_nlink_2")
    ) { receiptURL in
      try FileManager.default.linkItem(
        at: receiptURL,
        to: receiptURL.deletingLastPathComponent()
          .appendingPathComponent("receipt-hard-link"))
    }

    let oversizedCount = 64 * 1024 + 1
    try assertInvalidInitializedReceipt(
      expectedError: .invalidArtifact(
        path: "<receipt>",
        reason: "invalid_receipt_size_\(oversizedCount)")
    ) { receiptURL in
      try Data(count: oversizedCount).write(to: receiptURL)
      XCTAssertEqual(chmod(receiptURL.path, 0o600), 0)
    }

    try assertInvalidInitializedReceipt(
      expectedError: .artifactOpenFailed(
        path: "<receipt>",
        code: ELOOP)
    ) { receiptURL in
      let moved = receiptURL.deletingLastPathComponent()
        .appendingPathComponent("symlink-target-receipt")
      try FileManager.default.moveItem(at: receiptURL, to: moved)
      try FileManager.default.createSymbolicLink(
        at: receiptURL, withDestinationURL: moved)
    }
  }

  func testFlockFailureFailsClosedBeforeBody() throws {
    try withTemporaryGoalStoreRoot { root in
      _ = try TatwoGoalStoreGlobalLock.initializeCreateOnly(
        goalStoreRoot: root)
      let lockURL = TatwoGoalStoreGlobalLock.lockURL(forGoalStoreRoot: root)
      let hooks = TatwoGoalStoreGlobalLockHooks(
        flockOperation: { _, _ in -1 },
        errnoProvider: { EIO },
        afterLockOpen: {},
        afterLockDurable: {})
      var executed = false

      XCTAssertThrowsError(
        try TatwoGoalStoreGlobalLock.withExclusiveLock(
          goalStoreRoot: root,
          expectedUserID: getuid(),
          expectedGroupID: getgid(),
          hooks: hooks
        ) {
          executed = true
        }) { error in
          XCTAssertEqual(
            error as? TatwoGoalStoreGlobalLockError,
            .acquireFailed(path: lockURL.path, code: EIO))
        }
      XCTAssertFalse(executed)
    }
  }

  private func assertInvalidInitializedReceipt(
    expectedReceiptUserID: uid_t? = nil,
    expectedReceiptGroupID: gid_t? = nil,
    expectedError: TatwoGoalStoreGlobalLockError,
    configure: (URL) throws -> Void
  ) throws {
    try withTemporaryGoalStoreRoot { root in
      _ = try TatwoGoalStoreGlobalLock.initializeCreateOnly(
        goalStoreRoot: root)
      let receiptURL =
        TatwoGoalStoreGlobalLock.initializationReceiptURL(
          forGoalStoreRoot: root)
      try configure(receiptURL)
      var executed = false

      XCTAssertThrowsError(
        try TatwoGoalStoreGlobalLock.withExclusiveLock(
          goalStoreRoot: root,
          expectedUserID: getuid(),
          expectedGroupID: getgid(),
          expectedReceiptUserID: expectedReceiptUserID,
          expectedReceiptGroupID: expectedReceiptGroupID,
          hooks: .production
        ) {
          executed = true
        }) { error in
          guard let actual = error as? TatwoGoalStoreGlobalLockError else {
            XCTFail("Unexpected error type: \(error)")
            return
          }
          switch (actual, expectedError) {
          case let (
            .invalidArtifact(actualPath, actualReason),
            .invalidArtifact(expectedPath, expectedReason)
          ):
            XCTAssertEqual(actualPath, receiptURL.path)
            XCTAssertEqual(expectedPath, "<receipt>")
            XCTAssertEqual(actualReason, expectedReason)
          case let (
            .artifactOpenFailed(actualPath, actualCode),
            .artifactOpenFailed(expectedPath, expectedCode)
          ):
            XCTAssertEqual(actualPath, receiptURL.path)
            XCTAssertEqual(expectedPath, "<receipt>")
            XCTAssertEqual(actualCode, expectedCode)
          default:
            XCTFail("Unexpected receipt validation error: \(actual)")
          }
        }
      XCTAssertFalse(executed)
    }
  }

  private func assertInvalidManualLock(
    expectedUserID: uid_t = getuid(),
    configure: (URL) throws -> Void
  ) throws {
    try withTemporaryGoalStoreRoot { root in
      let lockURL = TatwoGoalStoreGlobalLock.lockURL(forGoalStoreRoot: root)
      try configure(lockURL)
      let hooks = TatwoGoalStoreGlobalLockHooks.production
      var executed = false

      XCTAssertThrowsError(
        try TatwoGoalStoreGlobalLock.withExclusiveLock(
          goalStoreRoot: root,
          expectedUserID: expectedUserID,
          expectedGroupID: getgid(),
          hooks: hooks
        ) {
          executed = true
        })
      XCTAssertFalse(executed)
    }
  }

  private func withTemporaryGoalStoreRoot(
    _ body: (URL) throws -> Void
  ) throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "tatwo-goal-store-global-lock-\(UUID().uuidString)",
        isDirectory: true)
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    try body(root.standardizedFileURL)
  }
}
