import Foundation
import XCTest

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

@testable import TatwoUltraworkCore

final class GoalStoreLifecycleLockTests: XCTestCase {
  private let contractID = "contract-a1a"

  func testCanonicalPathsAndCreateOnlyExactReadbackThenStop() throws {
    try GoalStoreTestSupport.withTemporaryRoot { root in
      _ = try GoalStoreTestSupport.initializeGlobal(at: root)
      let createdAt = Date(timeIntervalSince1970: 1_786_118_401)
      let receipt = try TatwoGoalStoreLifecycleLock.initializeCreateOnly(
        goalStoreRoot: root,
        contractID: contractID,
        createdAt: createdAt)
      let directoryURL =
        TatwoGoalStoreLifecycleLock.lifecycleDirectoryURL(
          forGoalStoreRoot: root)
      let lockURL = try TatwoGoalStoreLifecycleLock.lockURL(
        forGoalStoreRoot: root, contractID: contractID)
      let receiptURL =
        try TatwoGoalStoreLifecycleLock.initializationReceiptURL(
          forGoalStoreRoot: root, contractID: contractID)

      XCTAssertEqual(
        lockURL.path,
        root.appendingPathComponent(
          "dispatch-lifecycle/\(contractID).state.lock").path)
      XCTAssertEqual(
        receiptURL.path,
        root.appendingPathComponent(
          "dispatch-lifecycle/\(contractID).state.lock.initialized.json"
        ).path)

      var directoryStatus = stat()
      var lockStatus = stat()
      var receiptStatus = stat()
      XCTAssertEqual(lstat(directoryURL.path, &directoryStatus), 0)
      XCTAssertEqual(directoryStatus.st_mode & S_IFMT, S_IFDIR)
      XCTAssertEqual(directoryStatus.st_mode & 0o7777, 0o700)
      XCTAssertEqual(lstat(lockURL.path, &lockStatus), 0)
      XCTAssertEqual(lockStatus.st_mode & S_IFMT, S_IFREG)
      XCTAssertEqual(lockStatus.st_mode & 0o7777, 0o600)
      XCTAssertEqual(lockStatus.st_nlink, 1)
      XCTAssertEqual(lockStatus.st_size, 0)
      XCTAssertEqual(lstat(receiptURL.path, &receiptStatus), 0)
      XCTAssertEqual(receiptStatus.st_mode & S_IFMT, S_IFREG)
      XCTAssertEqual(receiptStatus.st_mode & 0o7777, 0o600)
      XCTAssertEqual(receiptStatus.st_nlink, 1)
      XCTAssertGreaterThan(receiptStatus.st_size, 0)

      XCTAssertEqual(receipt.contractID, contractID)
      XCTAssertEqual(receipt.createdAt, createdAt)
      XCTAssertEqual(receipt.lockPath, lockURL.path)
      XCTAssertEqual(receipt.receiptPath, receiptURL.path)
      XCTAssertEqual(receipt.inode, UInt64(lockStatus.st_ino))
      XCTAssertEqual(
        receipt.lifecycleDirectoryInode,
        UInt64(directoryStatus.st_ino))
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      XCTAssertEqual(
        try decoder.decode(
          TatwoGoalStoreLifecycleLockInitializationReceiptV1.self,
          from: Data(contentsOf: receiptURL)),
        receipt)

      XCTAssertEqual(
        try GoalStoreTestSupport.relativeArtifacts(under: root),
        [
          ".tatwo-goal-store.global-lock.initialized.json",
          ".tatwo-goal-store.global.lock",
          "dispatch-lifecycle",
          "dispatch-lifecycle/\(contractID).state.lock",
          "dispatch-lifecycle/\(contractID).state.lock.initialized.json",
        ])
      XCTAssertFalse(
        FileManager.default.fileExists(
          atPath: root.appendingPathComponent("\(contractID).json").path))
      XCTAssertFalse(
        FileManager.default.fileExists(
          atPath: root.appendingPathComponent(
            "\(contractID).json.lock").path))
    }
  }

  func testDuplicateAndConcurrentInitializersFailClosed() async throws {
    try await GoalStoreTestSupport.withTemporaryRoot { root in
      _ = try GoalStoreTestSupport.initializeGlobal(at: root)
      let id = contractID
      let first = Task.detached {
        Result {
          try TatwoGoalStoreLifecycleLock.initializeCreateOnly(
            goalStoreRoot: root,
            contractID: id)
        }
      }
      let second = Task.detached {
        Result {
          try TatwoGoalStoreLifecycleLock.initializeCreateOnly(
            goalStoreRoot: root,
            contractID: id)
        }
      }
      let firstResult = await first.value
      let secondResult = await second.value
      let results = [firstResult, secondResult]
      XCTAssertEqual(
        results.filter {
          if case .success = $0 { return true }
          return false
        }.count,
        1)
      XCTAssertEqual(
        results.filter {
          if case .failure = $0 { return true }
          return false
        }.count,
        1)
    }
  }

  func testExistingOnlyAcquisitionPreservesIdentityAndRunsBody() throws {
    try GoalStoreTestSupport.withTemporaryRoot { root in
      _ = try GoalStoreTestSupport.initializeLifecycle(
        at: root, contractID: contractID)
      let lockURL = try TatwoGoalStoreLifecycleLock.lockURL(
        forGoalStoreRoot: root, contractID: contractID)
      let receiptURL =
        try TatwoGoalStoreLifecycleLock.initializationReceiptURL(
          forGoalStoreRoot: root, contractID: contractID)
      var beforeLock = stat()
      XCTAssertEqual(lstat(lockURL.path, &beforeLock), 0)
      let beforeReceipt = try Data(contentsOf: receiptURL)
      var executed = false

      let value = try TatwoGoalStoreLifecycleLock.withExclusiveLock(
        goalStoreRoot: root,
        contractID: contractID
      ) {
        executed = true
        XCTAssertEqual(
          TatwoGoalStoreLockOrder.heldKinds,
          [.lifecycle])
        return 42
      }

      var afterLock = stat()
      XCTAssertEqual(lstat(lockURL.path, &afterLock), 0)
      XCTAssertTrue(executed)
      XCTAssertEqual(value, 42)
      XCTAssertEqual(beforeLock.st_dev, afterLock.st_dev)
      XCTAssertEqual(beforeLock.st_ino, afterLock.st_ino)
      XCTAssertEqual(try Data(contentsOf: receiptURL), beforeReceipt)
    }
  }

  func testMissingExistingOnlyAcquisitionCreatesNothing() throws {
    try GoalStoreTestSupport.withTemporaryRoot { root in
      _ = try GoalStoreTestSupport.initializeGlobal(at: root)
      let before = try GoalStoreTestSupport.relativeArtifacts(under: root)
      var executed = false

      XCTAssertThrowsError(
        try TatwoGoalStoreLifecycleLock.withExclusiveLock(
          goalStoreRoot: root,
          contractID: contractID
        ) {
          executed = true
        }) { error in
          XCTAssertEqual(
            error as? TatwoGoalStoreLifecycleLockError,
            .artifactMissing(
              path: TatwoGoalStoreLifecycleLock.lifecycleDirectoryURL(
                forGoalStoreRoot: root).path))
        }
      XCTAssertFalse(executed)
      XCTAssertEqual(
        try GoalStoreTestSupport.relativeArtifacts(under: root),
        before)
    }
  }

  func testDirectoryOnlyAndLockOnlyPartialStatesRemainVisible() throws {
    try GoalStoreTestSupport.withTemporaryRoot { root in
      _ = try GoalStoreTestSupport.initializeGlobal(at: root)
      let directoryURL =
        TatwoGoalStoreLifecycleLock.lifecycleDirectoryURL(
          forGoalStoreRoot: root)
      try FileManager.default.createDirectory(
        at: directoryURL,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])

      XCTAssertThrowsError(
        try TatwoGoalStoreLifecycleLock.withExclusiveLock(
          goalStoreRoot: root,
          contractID: contractID,
          {}))
      XCTAssertThrowsError(
        try TatwoGoalStoreLifecycleLock.initializeCreateOnly(
          goalStoreRoot: root,
          contractID: contractID))
      XCTAssertTrue(
        FileManager.default.fileExists(atPath: directoryURL.path))
    }

    try GoalStoreTestSupport.withTemporaryRoot { root in
      _ = try GoalStoreTestSupport.initializeGlobal(at: root)
      let directoryURL =
        TatwoGoalStoreLifecycleLock.lifecycleDirectoryURL(
          forGoalStoreRoot: root)
      try FileManager.default.createDirectory(
        at: directoryURL,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
      let lockURL = try TatwoGoalStoreLifecycleLock.lockURL(
        forGoalStoreRoot: root, contractID: contractID)
      XCTAssertTrue(
        FileManager.default.createFile(
          atPath: lockURL.path,
          contents: Data(),
          attributes: [.posixPermissions: 0o600]))

      XCTAssertThrowsError(
        try TatwoGoalStoreLifecycleLock.withExclusiveLock(
          goalStoreRoot: root,
          contractID: contractID,
          {}))
      XCTAssertThrowsError(
        try TatwoGoalStoreLifecycleLock.initializeCreateOnly(
          goalStoreRoot: root,
          contractID: contractID))
      XCTAssertTrue(FileManager.default.fileExists(atPath: lockURL.path))
      XCTAssertFalse(
        FileManager.default.fileExists(
          atPath: try TatwoGoalStoreLifecycleLock
            .initializationReceiptURL(
              forGoalStoreRoot: root,
              contractID: contractID).path))
    }
  }

  func testInitializerCrashWindowsRemainVisibleWithoutRepair() throws {
    enum Marker: Error { case expected }

    try GoalStoreTestSupport.withTemporaryRoot { root in
      _ = try GoalStoreTestSupport.initializeGlobal(at: root)
      let hooks = makeHooks(afterDirectoryDurable: {
        throw Marker.expected
      })
      XCTAssertThrowsError(
        try TatwoGoalStoreLifecycleLock.initializeCreateOnly(
          goalStoreRoot: root,
          contractID: contractID,
          createdAt: Date(),
          globalHooks: .production,
          lifecycleHooks: hooks))
      XCTAssertEqual(
        try GoalStoreTestSupport.relativeArtifacts(under: root),
        [
          ".tatwo-goal-store.global-lock.initialized.json",
          ".tatwo-goal-store.global.lock",
          "dispatch-lifecycle",
        ])
      XCTAssertThrowsError(
        try TatwoGoalStoreLifecycleLock.withExclusiveLock(
          goalStoreRoot: root,
          contractID: contractID,
          {}))
    }

    try GoalStoreTestSupport.withTemporaryRoot { root in
      _ = try GoalStoreTestSupport.initializeGlobal(at: root)
      let hooks = makeHooks(afterLockDurable: {
        throw Marker.expected
      })
      XCTAssertThrowsError(
        try TatwoGoalStoreLifecycleLock.initializeCreateOnly(
          goalStoreRoot: root,
          contractID: contractID,
          createdAt: Date(),
          globalHooks: .production,
          lifecycleHooks: hooks))
      XCTAssertEqual(
        try GoalStoreTestSupport.relativeArtifacts(under: root),
        [
          ".tatwo-goal-store.global-lock.initialized.json",
          ".tatwo-goal-store.global.lock",
          "dispatch-lifecycle",
          "dispatch-lifecycle/\(contractID).state.lock",
        ])
      XCTAssertThrowsError(
        try TatwoGoalStoreLifecycleLock.withExclusiveLock(
          goalStoreRoot: root,
          contractID: contractID,
          {}))
    }
  }

  func testDirectoryLockAndReceiptSymlinksFailClosed() throws {
    try assertInitializedMutationFails { root, _, _ in
      let directoryURL =
        TatwoGoalStoreLifecycleLock.lifecycleDirectoryURL(
          forGoalStoreRoot: root)
      let moved = root.appendingPathComponent("moved-lifecycle")
      try FileManager.default.moveItem(at: directoryURL, to: moved)
      try FileManager.default.createSymbolicLink(
        at: directoryURL, withDestinationURL: moved)
    }

    try assertInitializedMutationFails { root, lockURL, _ in
      let moved = root.appendingPathComponent("moved-lock")
      try FileManager.default.moveItem(at: lockURL, to: moved)
      try FileManager.default.createSymbolicLink(
        at: lockURL, withDestinationURL: moved)
    }

    try assertInitializedMutationFails { root, _, receiptURL in
      let moved = root.appendingPathComponent("moved-receipt")
      try FileManager.default.moveItem(at: receiptURL, to: moved)
      try FileManager.default.createSymbolicLink(
        at: receiptURL, withDestinationURL: moved)
    }
  }

  func testWrongTypeModeOwnerNlinkAndSizeFailClosed() throws {
    try assertInitializedMutationFails { _, lockURL, _ in
      try Data("x".utf8).write(to: lockURL)
      XCTAssertEqual(chmod(lockURL.path, 0o600), 0)
    }
    try assertInitializedMutationFails { _, lockURL, _ in
      XCTAssertEqual(chmod(lockURL.path, 0o644), 0)
    }
    try assertInitializedMutationFails { root, lockURL, _ in
      try FileManager.default.linkItem(
        at: lockURL,
        to: root.appendingPathComponent("hard-link"))
    }
    try assertInitializedMutationFails { root, lockURL, _ in
      try FileManager.default.moveItem(
        at: lockURL,
        to: root.appendingPathComponent("moved-regular-lock"))
      try FileManager.default.createDirectory(
        at: lockURL, withIntermediateDirectories: false)
    }
    try assertInitializedMutationFails(
      expectedUserID: getuid() &+ 1
    ) { _, _, _ in }
    try assertInitializedMutationFails { root, _, _ in
      XCTAssertEqual(
        chmod(
          TatwoGoalStoreLifecycleLock.lifecycleDirectoryURL(
            forGoalStoreRoot: root).path,
          0o755),
        0)
    }
  }

  func testPathReplacementAndReceiptBoundLockReplacementFailClosed() throws {
    try GoalStoreTestSupport.withTemporaryRoot { root in
      _ = try GoalStoreTestSupport.initializeLifecycle(
        at: root, contractID: contractID)
      let lockURL = try TatwoGoalStoreLifecycleLock.lockURL(
        forGoalStoreRoot: root, contractID: contractID)
      let moved = root.appendingPathComponent("opened-lock")
      let hooks = makeHooks(afterLockOpen: {
        try FileManager.default.moveItem(at: lockURL, to: moved)
        XCTAssertTrue(
          FileManager.default.createFile(
            atPath: lockURL.path,
            contents: Data(),
            attributes: [.posixPermissions: 0o600]))
      })
      var executed = false

      XCTAssertThrowsError(
        try TatwoGoalStoreLifecycleLock.withExclusiveLock(
          goalStoreRoot: root,
          contractID: contractID,
          expectedUserID: getuid(),
          expectedGroupID: getgid(),
          hooks: hooks
        ) {
          executed = true
        }) { error in
          XCTAssertEqual(
            error as? TatwoGoalStoreLifecycleLockError,
            .artifactIdentityMismatch(path: lockURL.path))
        }
      XCTAssertFalse(executed)
    }

    try GoalStoreTestSupport.withTemporaryRoot { root in
      _ = try GoalStoreTestSupport.initializeLifecycle(
        at: root, contractID: contractID)
      let lockURL = try TatwoGoalStoreLifecycleLock.lockURL(
        forGoalStoreRoot: root, contractID: contractID)
      try FileManager.default.moveItem(
        at: lockURL,
        to: root.appendingPathComponent("original-lock"))
      XCTAssertTrue(
        FileManager.default.createFile(
          atPath: lockURL.path,
          contents: Data(),
          attributes: [.posixPermissions: 0o600]))
      var executed = false
      XCTAssertThrowsError(
        try TatwoGoalStoreLifecycleLock.withExclusiveLock(
          goalStoreRoot: root,
          contractID: contractID
        ) {
          executed = true
        })
      XCTAssertFalse(executed)
    }
  }

  func testFlockFailurePreventsBody() throws {
    try GoalStoreTestSupport.withTemporaryRoot { root in
      _ = try GoalStoreTestSupport.initializeLifecycle(
        at: root, contractID: contractID)
      let lockURL = try TatwoGoalStoreLifecycleLock.lockURL(
        forGoalStoreRoot: root, contractID: contractID)
      let hooks = makeHooks(
        flockOperation: { _, _ in -1 },
        errnoProvider: { EIO })
      var executed = false

      XCTAssertThrowsError(
        try TatwoGoalStoreLifecycleLock.withExclusiveLock(
          goalStoreRoot: root,
          contractID: contractID,
          expectedUserID: getuid(),
          expectedGroupID: getgid(),
          hooks: hooks
        ) {
          executed = true
        }) { error in
          XCTAssertEqual(
            error as? TatwoGoalStoreLifecycleLockError,
            .acquireFailed(path: lockURL.path, code: EIO))
        }
      XCTAssertFalse(executed)
    }
  }

  func testGlobalLockOrReceiptReplacementBreaksLifecycleBinding() throws {
    try GoalStoreTestSupport.withTemporaryRoot { root in
      _ = try GoalStoreTestSupport.initializeLifecycle(
        at: root, contractID: contractID)
      let globalLock =
        TatwoGoalStoreGlobalLock.lockURL(forGoalStoreRoot: root)
      try FileManager.default.moveItem(
        at: globalLock,
        to: root.appendingPathComponent("original-global"))
      XCTAssertTrue(
        FileManager.default.createFile(
          atPath: globalLock.path,
          contents: Data(),
          attributes: [.posixPermissions: 0o600]))
      var executed = false

      XCTAssertThrowsError(
        try TatwoGoalStoreLifecycleLock.withExclusiveLock(
          goalStoreRoot: root,
          contractID: contractID
        ) {
          executed = true
        })
      XCTAssertFalse(executed)
    }
  }

  private func assertInitializedMutationFails(
    expectedUserID: uid_t = getuid(),
    mutation: (URL, URL, URL) throws -> Void
  ) throws {
    try GoalStoreTestSupport.withTemporaryRoot { root in
      _ = try GoalStoreTestSupport.initializeLifecycle(
        at: root, contractID: contractID)
      let lockURL = try TatwoGoalStoreLifecycleLock.lockURL(
        forGoalStoreRoot: root, contractID: contractID)
      let receiptURL =
        try TatwoGoalStoreLifecycleLock.initializationReceiptURL(
          forGoalStoreRoot: root, contractID: contractID)
      try mutation(root, lockURL, receiptURL)
      var executed = false

      XCTAssertThrowsError(
        try TatwoGoalStoreLifecycleLock.withExclusiveLock(
          goalStoreRoot: root,
          contractID: contractID,
          expectedUserID: expectedUserID,
          expectedGroupID: getgid(),
          hooks: .production
        ) {
          executed = true
        })
      XCTAssertFalse(executed)
    }
  }

  private func makeHooks(
    flockOperation: @escaping (Int32, Int32) -> Int32 = {
      flock($0, $1)
    },
    errnoProvider: @escaping () -> Int32 = { errno },
    afterDirectoryDurable: @escaping () throws -> Void = {},
    afterLockOpen: @escaping () throws -> Void = {},
    afterLockDurable: @escaping () throws -> Void = {},
    afterReceiptDurable: @escaping () throws -> Void = {},
    afterFlock: @escaping () throws -> Void = {}
  ) -> TatwoGoalStoreLifecycleLockHooks {
    TatwoGoalStoreLifecycleLockHooks(
      flockOperation: flockOperation,
      errnoProvider: errnoProvider,
      afterDirectoryDurable: afterDirectoryDurable,
      afterLockOpen: afterLockOpen,
      afterLockDurable: afterLockDurable,
      afterReceiptDurable: afterReceiptDurable,
      afterFlock: afterFlock)
  }
}
