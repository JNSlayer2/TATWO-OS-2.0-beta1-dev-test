import CryptoKit
import Foundation

/// Phase 3: a real submission seal.
///
/// The arena previously wrote `seal.json` with `sealed:false` and `fileHashes:{}` and never
/// computed or re-verified anything — so a model could drop a `評分報告.json` with
/// `finalScore:100` and `runSummary` aggregated it as truth. This type makes the seal
/// trust-on-verify: `seal(directory:)` records a SHA256 of every file in a submission, and
/// `verify(directory:against:)` re-hashes and reports any post-seal change.
public struct TatwoArenaSubmissionSeal: Codable, Sendable, Equatable {
  public let schema: String
  public let sealed: Bool
  public let algorithm: String
  /// POSIX relative path (under the sealed directory) → hex SHA256.
  public let fileHashes: [String: String]
  public let note: String
  /// Provenance: hex HMAC-SHA256 over the canonical fileHashes, keyed by a grader-held secret.
  /// nil = unsigned (tamper-evidence only). A model can hash its own project, but without the
  /// grader key it cannot produce a valid signature — so a signed verify rejects a self-seal.
  public let signature: String?

  public init(
    schema: String = "TatwoArenaSubmissionSealV1",
    sealed: Bool,
    algorithm: String = "sha256",
    fileHashes: [String: String],
    note: String = "",
    signature: String? = nil
  ) {
    self.schema = schema
    self.sealed = sealed
    self.algorithm = algorithm
    self.fileHashes = fileHashes
    self.note = note
    self.signature = signature
  }

  private enum CodingKeys: String, CodingKey {
    case schema, sealed, algorithm, fileHashes, note, signature
  }

  // Lenient decode: the arena scaffold's seal.json is a superset (caseID, modelSlug, …) and
  // omits `algorithm`. Only `sealed` and `fileHashes` are required; the rest default.
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.schema = try c.decodeIfPresent(String.self, forKey: .schema) ?? "TatwoArenaSubmissionSealV1"
    self.sealed = try c.decode(Bool.self, forKey: .sealed)
    self.algorithm = try c.decodeIfPresent(String.self, forKey: .algorithm) ?? "sha256"
    self.fileHashes = try c.decodeIfPresent([String: String].self, forKey: .fileHashes) ?? [:]
    self.note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
    self.signature = try c.decodeIfPresent(String.self, forKey: .signature)
  }
}

public struct TatwoArenaSealVerification: Codable, Sendable, Equatable {
  public let verified: Bool
  public let reason: String
  public let changed: [String]
  public let added: [String]
  public let removed: [String]
  public let checkedFileCount: Int

  public init(
    verified: Bool, reason: String, changed: [String], added: [String],
    removed: [String], checkedFileCount: Int
  ) {
    self.verified = verified
    self.reason = reason
    self.changed = changed
    self.added = added
    self.removed = removed
    self.checkedFileCount = checkedFileCount
  }
}

public enum TatwoArenaSubmissionSealer {
  public static func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  /// Deterministic string over the file hashes, so the same submission always signs identically.
  static func canonicalPayload(_ fileHashes: [String: String]) -> String {
    fileHashes.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: "\n")
  }

  /// hex HMAC-SHA256 of the canonical file hashes under `key` (the grader secret).
  public static func signature(forHashes fileHashes: [String: String], key: String) -> String {
    let mac = HMAC<SHA256>.authenticationCode(
      for: Data(canonicalPayload(fileHashes).utf8), using: SymmetricKey(data: Data(key.utf8)))
    return mac.map { String(format: "%02x", $0) }.joined()
  }

  /// Recursively hash every regular file under `directory`, keyed by POSIX relative path.
  /// `exclude` names relative paths that should not be part of the seal (e.g. grader-written
  /// score files that legitimately change after sealing).
  public static func computeFileHashes(
    directory: URL, exclude: Set<String> = []
  ) throws -> [String: String] {
    let root = directory.standardizedFileURL
    var result: [String: String] = [:]
    guard
      let enumerator = FileManager.default.enumerator(
        at: root, includingPropertiesForKeys: [.isRegularFileKey])
    else { return result }
    for case let url as URL in enumerator {
      let isRegular =
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
      guard isRegular else { continue }
      let rel = relativePath(of: url, under: root)
      if exclude.contains(rel) { continue }
      result[rel] = sha256Hex(try Data(contentsOf: url))
    }
    return result
  }

  /// Compute a sealed seal over `directory`. When `signingKey` is provided, the seal is signed
  /// with a grader HMAC so a later verify can prove provenance (not just tamper-freeness).
  public static func seal(directory: URL, exclude: Set<String> = [], signingKey: String? = nil)
    throws -> TatwoArenaSubmissionSeal
  {
    let hashes = try computeFileHashes(directory: directory, exclude: exclude)
    return TatwoArenaSubmissionSeal(
      sealed: true,
      fileHashes: hashes,
      note: "Sealed over \(hashes.count) files; any post-seal change invalidates the submission.",
      signature: signingKey.map { signature(forHashes: hashes, key: $0) })
  }

  /// Re-hash `directory` and compare against a sealed seal. An unsealed seal never verifies.
  /// When `signingKey` is provided, the seal must ALSO carry a valid grader signature over its
  /// recorded hashes — a model that self-sealed without the key is rejected as unauthorized.
  public static func verify(
    directory: URL, against seal: TatwoArenaSubmissionSeal, exclude: Set<String> = [],
    signingKey: String? = nil
  ) throws -> TatwoArenaSealVerification {
    guard seal.sealed else {
      return TatwoArenaSealVerification(
        verified: false, reason: "seal_not_sealed", changed: [], added: [], removed: [],
        checkedFileCount: 0)
    }
    if let signingKey {
      let expectedSig = signature(forHashes: seal.fileHashes, key: signingKey)
      guard let sig = seal.signature, sig == expectedSig else {
        return TatwoArenaSealVerification(
          verified: false, reason: seal.signature == nil ? "unsigned" : "signature_mismatch",
          changed: [], added: [], removed: [], checkedFileCount: 0)
      }
    }
    let current = try computeFileHashes(directory: directory, exclude: exclude)
    let expected = seal.fileHashes
    var changed: [String] = []
    var added: [String] = []
    for (path, hash) in current {
      if let want = expected[path] {
        if want != hash { changed.append(path) }
      } else {
        added.append(path)
      }
    }
    let removed = expected.keys.filter { current[$0] == nil }
    let verified = changed.isEmpty && added.isEmpty && removed.isEmpty
    return TatwoArenaSealVerification(
      verified: verified,
      reason: verified ? "ok" : "hash_mismatch",
      changed: changed.sorted(),
      added: added.sorted(),
      removed: removed.sorted(),
      checkedFileCount: current.count)
  }

  private static func relativePath(of url: URL, under root: URL) -> String {
    let full = url.standardizedFileURL.path
    let base = root.path.hasSuffix("/") ? root.path : root.path + "/"
    return full.hasPrefix(base) ? String(full.dropFirst(base.count)) : url.lastPathComponent
  }
}
