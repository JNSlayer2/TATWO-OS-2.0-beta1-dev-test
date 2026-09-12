import Foundation
import XCTest
#if canImport(Security)
import LocalAuthentication
import Security
#endif

@testable import TatwoUltraworkCore

final class TatwoProductionInstallAnchorKeychainStoreTests: XCTestCase {
  #if canImport(Security)
  func testReadQueryFailsInsteadOfPresentingAuthenticationUI() throws {
    let query = TatwoProductionInstallAnchorKeychainStore.readQuery(
      service: "ai.tatwo.test.production-layout",
      account: "test-layout")

    let context = try XCTUnwrap(
      query[kSecUseAuthenticationContext as String] as? LAContext)
    XCTAssertTrue(context.interactionNotAllowed)
    XCTAssertEqual(
      query[kSecUseAuthenticationUI as String] as? String,
      kSecUseAuthenticationUIFail as String)
  }

  func testInjectedSuccessfulReadDecodesInstallAnchor() throws {
    let anchor = makeAnchor()
    let data = try JSONEncoder().encode(anchor)
    let store = TatwoProductionInstallAnchorKeychainStore(
      readTimeoutSeconds: 1
    ) { _, _ in
      return TatwoProductionInstallAnchorKeychainReadResult(
        status: Int32(errSecSuccess),
        data: data)
    }

    XCTAssertEqual(try store.load(), anchor)
  }

  func testInjectedMissingItemReturnsNil() throws {
    let store = TatwoProductionInstallAnchorKeychainStore(
      readTimeoutSeconds: 1
    ) { _, _ in
      TatwoProductionInstallAnchorKeychainReadResult(
        status: Int32(errSecItemNotFound),
        data: nil)
    }

    XCTAssertNil(try store.load())
  }

  func testInjectedInteractionDenialIsExplicit() {
    let store = TatwoProductionInstallAnchorKeychainStore(
      readTimeoutSeconds: 1
    ) { _, _ in
      TatwoProductionInstallAnchorKeychainReadResult(
        status: Int32(errSecInteractionNotAllowed),
        data: nil)
    }

    XCTAssertThrowsError(try store.load()) { error in
      XCTAssertEqual(
        error as? TatwoProductionLayoutError,
        .installAnchorAuthenticationInteractionDenied)
    }
  }

  func testInjectedReadTimesOutBeforeOperationFinishes() {
    let store = TatwoProductionInstallAnchorKeychainStore(
      readTimeoutSeconds: 0.02
    ) { _, _ in
      Thread.sleep(forTimeInterval: 0.25)
      return TatwoProductionInstallAnchorKeychainReadResult(
        status: Int32(errSecItemNotFound),
        data: nil)
    }
    let startedAt = Date()

    XCTAssertThrowsError(try store.load()) { error in
      XCTAssertEqual(
        error as? TatwoProductionLayoutError,
        .installAnchorReadTimeout)
    }
    XCTAssertLessThan(
      Date().timeIntervalSince(startedAt),
      0.22,
      "timeout must return before the injected operation finishes")
  }

  func testInjectedMalformedDataFailsClosed() {
    let store = TatwoProductionInstallAnchorKeychainStore(
      readTimeoutSeconds: 1
    ) { _, _ in
      TatwoProductionInstallAnchorKeychainReadResult(
        status: Int32(errSecSuccess),
        data: Data("not-json".utf8))
    }

    XCTAssertThrowsError(try store.load()) { error in
      guard case let TatwoProductionLayoutError.installAnchorRejected(detail) = error else {
        return XCTFail("unexpected error: \(error)")
      }
      XCTAssertTrue(detail.contains("decode failed"))
    }
  }

  private func makeAnchor() -> TatwoProductionInstallAnchorV1 {
    TatwoProductionInstallAnchorV1(
      hostDeviceID: "device-test",
      applicationSupportRoot: "/Library/Application Support/Tatwo Ultrawork",
      stateRoot: "/Library/Application Support/Tatwo Ultrawork/state",
      pinStoreRoot: "/Library/Application Support/Tatwo Ultrawork/pins",
      jobChannelRoot: "/Library/Application Support/Tatwo Ultrawork/jobs",
      sealedAt: "2026-08-05T12:00:00Z")
  }
  #endif
}
