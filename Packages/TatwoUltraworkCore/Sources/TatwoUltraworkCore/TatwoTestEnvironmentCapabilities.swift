import Foundation
#if canImport(Security)
import Security
#endif

/// Runtime capability detection for tests whose correctness depends on host services.
///
/// The shared `current` instance caches each capability result for the lifetime of
/// the test process so a suite does not repeatedly touch the host service.
public final class TatwoTestEnvironmentCapabilities: @unchecked Sendable {
  public enum InteractiveKeychainAvailability: Equatable, Sendable {
    case available
    case interactionUnavailable(status: Int32)
    case probeFailed(status: Int32)
    case unavailableOnPlatform

    public var isAvailable: Bool {
      self == .available
    }
  }

  public static let current = TatwoTestEnvironmentCapabilities()
  public static let errSecInteractionNotAllowedStatus: Int32 = -25_308
  static let errSecItemNotFoundStatus: Int32 = -25_300

  private typealias KeychainCreateOnlyProbe = @Sendable () -> Int32?

  private let lock = NSLock()
  private let keychainCreateOnlyProbe: KeychainCreateOnlyProbe
  private var cachedInteractiveKeychainAvailability: InteractiveKeychainAvailability?

  public convenience init() {
    self.init(keychainCreateOnlyProbe: { Self.liveKeychainCreateOnlyProbe() })
  }

  init(keychainCreateOnlyProbe: @escaping @Sendable () -> Int32?) {
    self.keychainCreateOnlyProbe = keychainCreateOnlyProbe
  }

  /// Whether this process can create and clean up an isolated Keychain item
  /// without authentication UI. The result is probed once and then cached.
  public func interactiveKeychainAvailability() -> InteractiveKeychainAvailability {
    lock.lock()
    defer { lock.unlock() }

    if let cachedInteractiveKeychainAvailability {
      return cachedInteractiveKeychainAvailability
    }

    let availability: InteractiveKeychainAvailability
    guard let status = keychainCreateOnlyProbe() else {
      availability = .unavailableOnPlatform
      cachedInteractiveKeychainAvailability = availability
      return availability
    }

    switch status {
    case 0:
      availability = .available
    case Self.errSecInteractionNotAllowedStatus:
      availability = .interactionUnavailable(status: status)
    default:
      availability = .probeFailed(status: status)
    }
    cachedInteractiveKeychainAvailability = availability
    return availability
  }

  /// Performs a create-only probe against a unique service/account pair and
  /// deletes exactly that probe item before reporting success.
  private static func liveKeychainCreateOnlyProbe() -> Int32? {
    #if canImport(Security)
    let nonce = UUID().uuidString
    let service = "ai.tatwo.ultrawork.test-capability.keychain.\(nonce)"
    let account = "create-only-probe.\(nonce)"
    let identity: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    var add = identity
    add[kSecValueData as String] = Data("tatwo-keychain-capability-probe".utf8)
    add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    add[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail

    var cleanup = identity
    cleanup[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
    return performCreateOnlyKeychainProbe(
      create: { Int32(SecItemAdd(add as CFDictionary, nil)) },
      cleanup: { Int32(SecItemDelete(cleanup as CFDictionary)) })
    #else
    return nil
    #endif
  }

  /// Keeps the create-only ownership boundary explicit: cleanup runs only when
  /// this probe created the item. After creation, a deferred best-effort cleanup
  /// protects future early exits while the returned status still reports an
  /// explicit cleanup failure. A failed cleanup gets one best-effort retry
  /// against the same unique identity before the capability is classified.
  static func performCreateOnlyKeychainProbe(
    create: () -> Int32,
    cleanup: () -> Int32
  ) -> Int32 {
    let addStatus = create()
    guard addStatus == 0 else {
      return addStatus
    }

    var cleanupAttemptCount = 0
    defer {
      if cleanupAttemptCount == 0 {
        _ = cleanup()
      }
    }

    let firstCleanupStatus = cleanup()
    cleanupAttemptCount += 1
    if firstCleanupStatus == 0 || firstCleanupStatus == errSecItemNotFoundStatus {
      return 0
    }

    let retryCleanupStatus = cleanup()
    cleanupAttemptCount += 1
    if retryCleanupStatus == 0 || retryCleanupStatus == errSecItemNotFoundStatus {
      return 0
    }
    return firstCleanupStatus
  }
}
