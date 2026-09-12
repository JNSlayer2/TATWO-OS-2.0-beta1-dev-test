import Foundation
import XCTest

@testable import TatwoUltraworkCore

final class PluginLifecycleTests: XCTestCase {
  private let firstDate = Date(timeIntervalSince1970: 1_000)
  private let secondDate = Date(timeIntervalSince1970: 2_000)
  private let thirdDate = Date(timeIntervalSince1970: 3_000)

  func testInstallFromStagedTracksVersionRiskReceiptAndRollbackPointer() {
    let staged = record(
      state: .staged,
      source: .init(
        kind: .gitRepository,
        location: "https://example.invalid/plugin.git",
        version: "1.0.0",
        revision: "rev-1",
        sha256: "sha-1"))
    let risk = TatwoPluginLifecycleRiskV1(
      level: .medium,
      reasons: ["host_copy"],
      humanGateRequired: true)

    let result = transition(
      staged,
      .install(
        version: "1.0.0",
        revision: "rev-1",
        receiptID: "receipt-install",
        rollbackPointer: "backup/install-1",
        risk: risk),
      at: secondDate)

    XCTAssertTrue(result.accepted)
    XCTAssertNil(result.rejection)
    XCTAssertEqual(result.record.state, .installed)
    XCTAssertTrue(result.record.enabled)
    XCTAssertEqual(result.record.installedVersion, "1.0.0")
    XCTAssertEqual(result.record.installedRevision, "rev-1")
    XCTAssertNil(result.record.availableVersion)
    XCTAssertEqual(result.record.lastAction, .install)
    XCTAssertEqual(result.record.receiptIDs, ["receipt-install"])
    XCTAssertEqual(result.record.rollbackPointer, "backup/install-1")
    XCTAssertEqual(result.record.rollbackState, .staged)
    XCTAssertEqual(result.record.risk, risk)
    XCTAssertEqual(result.record.updatedAt, secondDate)
  }

  func testUpdateDiscoveryDoesNotInstallAvailableVersion() {
    let installed = record(
      state: .installed,
      enabled: true,
      installedVersion: "1.0.0",
      installedRevision: "rev-1")

    let result = transition(
      installed,
      .discoverUpdate(
        version: "2.0.0",
        revision: "rev-2",
        risk: .init(level: .high, reasons: ["major_version"])),
      at: secondDate)

    XCTAssertTrue(result.accepted)
    XCTAssertEqual(result.record.state, .updateAvailable)
    XCTAssertEqual(result.record.installedVersion, "1.0.0")
    XCTAssertEqual(result.record.installedRevision, "rev-1")
    XCTAssertEqual(result.record.availableVersion, "2.0.0")
    XCTAssertEqual(result.record.availableRevision, "rev-2")
    XCTAssertEqual(result.record.lastAction, .inspect)
  }

  func testUpdateRequiresAvailableStateAndRollbackPointer() {
    let installed = record(
      state: .installed,
      enabled: true,
      installedVersion: "1.0.0")
    let updateEvent = TatwoPluginLifecycleEventV1.update(
      version: "2.0.0",
      revision: nil,
      receiptID: "receipt-update",
      rollbackPointer: "backup/update-1",
      risk: .init(level: .high))

    let wrongState = transition(installed, updateEvent, at: secondDate)
    XCTAssertFalse(wrongState.accepted)
    XCTAssertEqual(wrongState.rejection, .invalidTransition)
    XCTAssertEqual(wrongState.record, installed)

    var updateAvailable = installed
    updateAvailable.state = .updateAvailable
    updateAvailable.availableVersion = "2.0.0"
    let missingRollback = transition(
      updateAvailable,
      .update(
        version: "2.0.0",
        revision: nil,
        receiptID: "receipt-update",
        rollbackPointer: " ",
        risk: .init(level: .high)),
      at: secondDate)

    XCTAssertFalse(missingRollback.accepted)
    XCTAssertEqual(missingRollback.rejection, .missingRollbackPointer)
    XCTAssertEqual(missingRollback.record, updateAvailable)
  }

  func testSuccessfulUpdateTracksPreviousVersionForRollback() {
    var updateAvailable = record(
      state: .updateAvailable,
      enabled: true,
      installedVersion: "1.0.0",
      installedRevision: "rev-1")
    updateAvailable.availableVersion = "2.0.0"
    updateAvailable.availableRevision = "rev-2"

    let result = transition(
      updateAvailable,
      .update(
        version: "2.0.0",
        revision: "rev-2",
        receiptID: "receipt-update",
        rollbackPointer: "backup/update-2",
        risk: .init(level: .high, reasons: ["managed_link_swap"])),
      at: secondDate)

    XCTAssertTrue(result.accepted)
    XCTAssertEqual(result.record.state, .installed)
    XCTAssertEqual(result.record.installedVersion, "2.0.0")
    XCTAssertEqual(result.record.installedRevision, "rev-2")
    XCTAssertNil(result.record.availableVersion)
    XCTAssertNil(result.record.availableRevision)
    XCTAssertEqual(result.record.rollbackVersion, "1.0.0")
    XCTAssertEqual(result.record.rollbackRevision, "rev-1")
    XCTAssertEqual(result.record.rollbackState, .updateAvailable)
    XCTAssertEqual(result.record.rollbackPointer, "backup/update-2")
    XCTAssertEqual(result.record.lastAction, .update)
  }

  func testUpdateRejectsTargetDifferentFromDiscoveredVersion() {
    var updateAvailable = record(
      state: .updateAvailable,
      enabled: true,
      installedVersion: "1.0.0")
    updateAvailable.availableVersion = "2.0.0"

    let result = transition(
      updateAvailable,
      .update(
        version: "3.0.0",
        revision: nil,
        receiptID: "receipt-update",
        rollbackPointer: "backup/update-3",
        risk: .init(level: .critical)),
      at: secondDate)

    XCTAssertFalse(result.accepted)
    XCTAssertEqual(result.rejection, .availableVersionMismatch)
    XCTAssertEqual(result.record, updateAvailable)
  }

  func testDisableThenEnableRestoresUpdateAvailableState() {
    var updateAvailable = record(
      state: .updateAvailable,
      enabled: true,
      installedVersion: "1.0.0")
    updateAvailable.availableVersion = "2.0.0"

    let disabled = transition(
      updateAvailable,
      .disable(
        receiptID: "receipt-disable",
        rollbackPointer: "backup/disable-1",
        risk: .init(level: .low)),
      at: secondDate)
    let enabled = transition(
      disabled.record,
      .enable(
        receiptID: "receipt-enable",
        risk: .init(level: .low)),
      at: thirdDate)

    XCTAssertTrue(disabled.accepted)
    XCTAssertEqual(disabled.record.state, .disabled)
    XCTAssertFalse(disabled.record.enabled)
    XCTAssertEqual(disabled.record.availableVersion, "2.0.0")
    XCTAssertEqual(disabled.record.rollbackState, .updateAvailable)

    XCTAssertTrue(enabled.accepted)
    XCTAssertEqual(enabled.record.state, .updateAvailable)
    XCTAssertTrue(enabled.record.enabled)
    XCTAssertEqual(enabled.record.installedVersion, "1.0.0")
    XCTAssertEqual(enabled.record.availableVersion, "2.0.0")
    XCTAssertEqual(enabled.record.receiptIDs, ["receipt-disable", "receipt-enable"])
  }

  func testEnableWithoutPendingUpdateReturnsInstalled() {
    let disabled = record(
      state: .disabled,
      enabled: false,
      installedVersion: "1.0.0")

    let result = transition(
      disabled,
      .enable(receiptID: "receipt-enable", risk: .init(level: .low)),
      at: secondDate)

    XCTAssertTrue(result.accepted)
    XCTAssertEqual(result.record.state, .installed)
    XCTAssertTrue(result.record.enabled)
  }

  func testInstallFromRegisteredIsRejectedWithoutMutation() {
    let registered = record(state: .registered)

    let result = transition(
      registered,
      .install(
        version: "1.0.0",
        revision: nil,
        receiptID: "receipt-install",
        rollbackPointer: nil,
        risk: .init(level: .medium)),
      at: secondDate)

    XCTAssertFalse(result.accepted)
    XCTAssertEqual(result.rejection, .invalidTransition)
    XCTAssertEqual(result.record, registered)
  }

  func testFailureCapturesRollbackSnapshotAndRollbackRestoresIt() {
    var updateAvailable = record(
      state: .updateAvailable,
      enabled: true,
      installedVersion: "1.0.0",
      installedRevision: "rev-1")
    updateAvailable.availableVersion = "2.0.0"
    updateAvailable.availableRevision = "rev-2"

    let failed = transition(
      updateAvailable,
      .fail(
        action: .update,
        errorCode: "smoke_failed",
        rollbackPointer: "backup/update-failed",
        rollbackRequired: true,
        receiptID: "receipt-failure",
        risk: .init(level: .critical, reasons: ["smoke_failed"])),
      at: secondDate)
    let rolledBack = transition(
      failed.record,
      .rollback(
        receiptID: "receipt-rollback",
        risk: .init(level: .medium, reasons: ["restored_backup"])),
      at: thirdDate)

    XCTAssertTrue(failed.accepted)
    XCTAssertEqual(failed.record.state, .rollbackRequired)
    XCTAssertFalse(failed.record.enabled)
    XCTAssertEqual(failed.record.lastErrorCode, "smoke_failed")
    XCTAssertEqual(failed.record.rollbackState, .updateAvailable)
    XCTAssertEqual(failed.record.rollbackVersion, "1.0.0")
    XCTAssertEqual(failed.record.rollbackRevision, "rev-1")

    XCTAssertTrue(rolledBack.accepted)
    XCTAssertEqual(rolledBack.record.state, .updateAvailable)
    XCTAssertTrue(rolledBack.record.enabled)
    XCTAssertEqual(rolledBack.record.installedVersion, "1.0.0")
    XCTAssertEqual(rolledBack.record.installedRevision, "rev-1")
    XCTAssertNil(rolledBack.record.lastErrorCode)
    XCTAssertEqual(rolledBack.record.lastAction, .rollback)
    XCTAssertEqual(
      rolledBack.record.receiptIDs,
      ["receipt-failure", "receipt-rollback"])
  }

  func testBlankAndDuplicateReceiptIDsAreNotRecorded() {
    var installed = record(
      state: .installed,
      enabled: true,
      installedVersion: "1.0.0")
    installed.receiptIDs = ["receipt-disable"]

    let disabled = transition(
      installed,
      .disable(
        receiptID: "receipt-disable",
        rollbackPointer: "backup/disable-2",
        risk: .init(level: .low)),
      at: secondDate)
    let enabled = transition(
      disabled.record,
      .enable(receiptID: " ", risk: .init(level: .low)),
      at: thirdDate)

    XCTAssertEqual(disabled.record.receiptIDs, ["receipt-disable"])
    XCTAssertEqual(enabled.record.receiptIDs, ["receipt-disable"])
  }

  func testLifecycleValuesHaveCodableValueSemantics() throws {
    let original = record(
      state: .installed,
      enabled: true,
      installedVersion: "1.0.0",
      installedRevision: "rev-1")
    var copy = original
    copy.availableVersion = "2.0.0"

    XCTAssertNotEqual(copy, original)
    XCTAssertNil(original.availableVersion)

    let decodedRecord = try JSONDecoder().decode(
      TatwoPluginLifecycleRecordV1.self,
      from: JSONEncoder().encode(original))
    XCTAssertEqual(decodedRecord, original)

    let event = TatwoPluginLifecycleEventV1.update(
      version: "2.0.0",
      revision: "rev-2",
      receiptID: "receipt-update",
      rollbackPointer: "backup/update-4",
      risk: .init(level: .high, reasons: ["version_change"]))
    let decodedEvent = try JSONDecoder().decode(
      TatwoPluginLifecycleEventV1.self,
      from: JSONEncoder().encode(event))
    XCTAssertEqual(decodedEvent, event)
  }

  private func record(
    state: TatwoPluginLifecycleStateV1,
    enabled: Bool = false,
    source: TatwoPluginSourceV1? = nil,
    installedVersion: String? = nil,
    installedRevision: String? = nil
  ) -> TatwoPluginLifecycleRecordV1 {
    TatwoPluginLifecycleRecordV1(
      entryID: "plugin.example",
      registryKind: .plugin,
      state: state,
      enabled: enabled,
      source: source,
      installedVersion: installedVersion,
      installedRevision: installedRevision,
      targetScope: "tatwo-staging",
      updatedAt: firstDate)
  }

  private func transition(
    _ record: TatwoPluginLifecycleRecordV1,
    _ event: TatwoPluginLifecycleEventV1,
    at date: Date
  ) -> TatwoPluginLifecycleTransitionV1 {
    TatwoPluginLifecycleReducer.transition(record: record, event: event, at: date)
  }
}
