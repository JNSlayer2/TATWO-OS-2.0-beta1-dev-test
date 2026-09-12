import Foundation
import XCTest

@testable import TatwoUltraworkCore

enum GoalStoreTestSupport {
  /// Happy-path close fixtures need the same terminal, sealed ledger evidence
  /// as execution contracts. Receipt submission alone does not prove dispatch.
  @discardableResult
  static func finalizeSuccessfulDispatch(
    contract: TatwoWorkOSContractV1,
    store: TatwoGoalRunStore,
    registry: TatwoDispatchRegistry
  ) throws -> TatwoStoredGoalRun {
    let binding = try XCTUnwrap(
      contract.identityBindings.first {
        TatwoExecutionManifestFactory.isDispatchable(modelID: $0.modelID)
      })
    let dispatch = try TatwoGoalRunDispatchLifecycle.begin(
      contractID: contract.contractID,
      bindingID: binding.id,
      sourceSlotID: binding.sourceSlotID,
      identity: binding.identity,
      modelID: try XCTUnwrap(binding.modelID),
      subtask: "test fixture terminal execution",
      helperCap: 1,
      goalStore: store,
      dispatchRegistry: registry)
    _ = try TatwoGoalRunDispatchLifecycle.update(
      contractID: contract.contractID,
      dispatchID: dispatch.id,
      status: .completed,
      receiptID: "fixture-terminal-\(dispatch.id)",
      outputRef: "tatwo-test://terminal/\(dispatch.id)",
      goalStore: store,
      dispatchRegistry: registry)
    return try TatwoGoalRunDispatchLifecycle.finalize(
      contractID: contract.contractID,
      goalStore: store,
      dispatchRegistry: registry)
  }

  static func withTemporaryRoot<T>(
    _ body: (URL) throws -> T
  ) throws -> T {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "tatwo-goal-store-a1a-\(UUID().uuidString)",
        isDirectory: true)
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    return try body(root.standardizedFileURL)
  }

  static func withTemporaryRoot<T>(
    _ body: (URL) async throws -> T
  ) async throws -> T {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "tatwo-goal-store-a1a-\(UUID().uuidString)",
        isDirectory: true)
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    return try await body(root.standardizedFileURL)
  }

  static func initializeGlobal(
    at root: URL,
    createdAt: Date = Date(timeIntervalSince1970: 1_786_118_400)
  ) throws -> TatwoGoalStoreGlobalLockInitializationReceiptV1 {
    try TatwoGoalStoreGlobalLock.initializeCreateOnly(
      goalStoreRoot: root,
      createdAt: createdAt)
  }

  static func initializeLifecycle(
    at root: URL,
    contractID: String = "contract-a1a",
    createdAt: Date = Date(timeIntervalSince1970: 1_786_118_401)
  ) throws -> TatwoGoalStoreLifecycleLockInitializationReceiptV1 {
    _ = try initializeGlobal(at: root)
    return try TatwoGoalStoreLifecycleLock.initializeCreateOnly(
      goalStoreRoot: root,
      contractID: contractID,
      createdAt: createdAt)
  }

  static func relativeArtifacts(under root: URL) throws -> [String] {
    let canonicalRootPath = root.resolvingSymlinksInPath().path
    guard let enumerator = FileManager.default.enumerator(
      at: root,
      includingPropertiesForKeys: nil,
      options: [],
      errorHandler: { _, _ in false })
    else {
      return []
    }
    return enumerator.compactMap { item -> String? in
      guard let url = item as? URL else { return nil }
      let canonicalItemPath = url.resolvingSymlinksInPath().path
      let prefix = canonicalRootPath + "/"
      guard canonicalItemPath.hasPrefix(prefix) else { return nil }
      return String(canonicalItemPath.dropFirst(prefix.count))
    }.sorted()
  }
}
