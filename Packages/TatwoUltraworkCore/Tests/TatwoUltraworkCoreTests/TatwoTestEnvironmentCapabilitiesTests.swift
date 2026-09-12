import XCTest

@testable import TatwoUltraworkCore

final class TatwoTestEnvironmentCapabilitiesTests: XCTestCase {
  func testInteractiveKeychainCapabilityReportsAvailableAndCachesProbe() {
    let probe = ProbeCounter(status: 0)
    let capabilities = TatwoTestEnvironmentCapabilities(
      keychainCreateOnlyProbe: { probe.run() })

    XCTAssertEqual(capabilities.interactiveKeychainAvailability(), .available)
    XCTAssertEqual(capabilities.interactiveKeychainAvailability(), .available)
    XCTAssertEqual(probe.count, 1, "capability result must be cached for the test process")
  }

  func testInteractiveKeychainCapabilityRecognizesInteractionNotAllowedAndCachesProbe() {
    let status = TatwoTestEnvironmentCapabilities.errSecInteractionNotAllowedStatus
    let probe = ProbeCounter(status: status)
    let capabilities = TatwoTestEnvironmentCapabilities(
      keychainCreateOnlyProbe: { probe.run() })

    XCTAssertEqual(
      capabilities.interactiveKeychainAvailability(),
      .interactionUnavailable(status: status))
    XCTAssertEqual(
      capabilities.interactiveKeychainAvailability(),
      .interactionUnavailable(status: status))
    XCTAssertEqual(probe.count, 1, "unavailable capability result must also be cached")
  }

  func testInteractiveKeychainCapabilityDoesNotMisclassifyOtherFailuresAsHeadlessSkip() {
    let capabilities = TatwoTestEnvironmentCapabilities(
      keychainCreateOnlyProbe: { -34_018 })

    XCTAssertEqual(
      capabilities.interactiveKeychainAvailability(),
      .probeFailed(status: -34_018))
  }

  func testCreateOnlyProbeRetriesExactCleanupAndReturnsOriginalFailure() {
    let cleanup = ProbeCounter(status: -34_018)

    let status = TatwoTestEnvironmentCapabilities.performCreateOnlyKeychainProbe(
      create: { 0 },
      cleanup: { cleanup.run() })

    XCTAssertEqual(status, -34_018)
    XCTAssertEqual(cleanup.count, 2)
  }

  func testCreateOnlyProbeAcceptsSuccessfulCleanupRetry() {
    let cleanup = SequencedProbe(statuses: [-34_018, 0])

    let status = TatwoTestEnvironmentCapabilities.performCreateOnlyKeychainProbe(
      create: { 0 },
      cleanup: { cleanup.run() })

    XCTAssertEqual(status, 0)
    XCTAssertEqual(cleanup.count, 2)
  }

  func testCreateOnlyProbeDoesNotDeleteWhenCreateDidNotOwnItem() {
    let cleanup = ProbeCounter(status: 0)

    let status = TatwoTestEnvironmentCapabilities.performCreateOnlyKeychainProbe(
      create: { -25_299 },
      cleanup: { cleanup.run() })

    XCTAssertEqual(status, -25_299)
    XCTAssertEqual(cleanup.count, 0, "failed create-only probe must not delete an unowned item")
  }
}

private final class SequencedProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var statuses: [Int32]
  private var value = 0

  init(statuses: [Int32]) {
    self.statuses = statuses
  }

  var count: Int {
    lock.lock()
    defer { lock.unlock() }
    return value
  }

  func run() -> Int32 {
    lock.lock()
    defer { lock.unlock() }
    let index = min(value, statuses.count - 1)
    value += 1
    return statuses[index]
  }
}

private final class ProbeCounter: @unchecked Sendable {
  private let lock = NSLock()
  private let status: Int32
  private var value = 0

  init(status: Int32) {
    self.status = status
  }

  var count: Int {
    lock.lock()
    defer { lock.unlock() }
    return value
  }

  func run() -> Int32 {
    lock.lock()
    defer { lock.unlock() }
    value += 1
    return status
  }
}
