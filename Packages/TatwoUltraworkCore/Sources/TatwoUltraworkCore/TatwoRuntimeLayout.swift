import Foundation

public enum TatwoRuntimeLayout {
  public static let appName = "Tatwo Ultrawork"
  public static let bundleIdentifier = "com.tatwo.ultrawork"
  public static let applicationSupportDirectoryName = "Tatwo Ultrawork"

  /// App Support `Tatwo Ultrawork/device-trust/` — local identity, peers, pin store.
  public static let deviceTrustDirectoryName = "device-trust"
  /// Durable co-signed pin + revocation records under `device-trust/pin-store/`.
  public static let deviceTrustPinStoreDirectoryName = "pin-store"
  public static let deviceTrustPinsDirectoryName = "pins"
  public static let deviceTrustRevocationsDirectoryName = "revocations"
  public static let deviceTrustPinStoreJournalFileName = "load-journal.jsonl"
  public static let deviceTrustLocalIdentityFileName = "identity.json"

  public static func applicationSupportRoot(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    applicationSupportBase: URL? = nil,
    fileManager: FileManager = .default
  ) -> URL {
    if let explicit = nonempty(environment["TATWO_ULTRAWORK_APP_SUPPORT"]) {
      return URL(fileURLWithPath: explicit, isDirectory: true).standardizedFileURL
    }
    let base =
      applicationSupportBase
      ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? fileManager.temporaryDirectory
    return base
      .appendingPathComponent(applicationSupportDirectoryName, isDirectory: true)
      .standardizedFileURL
  }

  public static func stateRoot(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    applicationSupportBase: URL? = nil,
    fileManager: FileManager = .default
  ) -> URL {
    if let explicit = nonempty(environment["TATWO_ULTRAWORK_STATE_DIR"]) {
      return URL(fileURLWithPath: explicit, isDirectory: true).standardizedFileURL
    }
    return applicationSupportRoot(
      environment: environment,
      applicationSupportBase: applicationSupportBase,
      fileManager: fileManager
    ).appendingPathComponent("state", isDirectory: true)
  }

  /// `…/Tatwo Ultrawork/device-trust/`
  public static func deviceTrustRoot(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    applicationSupportBase: URL? = nil,
    fileManager: FileManager = .default
  ) -> URL {
    applicationSupportRoot(
      environment: environment,
      applicationSupportBase: applicationSupportBase,
      fileManager: fileManager
    ).appendingPathComponent(deviceTrustDirectoryName, isDirectory: true)
  }

  /// `…/device-trust/pin-store/` — durable pins + revocations co-signed by local key.
  public static func deviceTrustPinStoreRoot(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    applicationSupportBase: URL? = nil,
    fileManager: FileManager = .default
  ) -> URL {
    deviceTrustRoot(
      environment: environment,
      applicationSupportBase: applicationSupportBase,
      fileManager: fileManager
    ).appendingPathComponent(deviceTrustPinStoreDirectoryName, isDirectory: true)
  }

  public static func legacyApplicationSupportRoots(
    applicationSupportBase: URL
  ) -> [URL] {
    let canonical = applicationSupportBase
      .appendingPathComponent(applicationSupportDirectoryName, isDirectory: true)
    return [
      canonical.appendingPathComponent("TatwoUltrawork", isDirectory: true),
      applicationSupportBase.appendingPathComponent("TatwoUltrawork", isDirectory: true),
    ]
  }

  private static func nonempty(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
      !trimmed.isEmpty
    else { return nil }
    return trimmed
  }
}

