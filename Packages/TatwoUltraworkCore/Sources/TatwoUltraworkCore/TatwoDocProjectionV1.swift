import CryptoKit
import Foundation

// MARK: - Domain Data Sync Plane B · 治理文件唯讀投影 S1
//
// Authority: docs/protocol/DEPLOYMENT_PLANES_DESIGN.md §B.2.3
//            docs/protocol/SKILLET_DOCS_PLACEMENT_DECISION.md
//
// One-way hard guarantee: mini/canonical → device only.
// There is intentionally **no** reverse / write-back API on this type.
// Receiver edits are invalid (verify → tampered); projector never writes source.

// MARK: - Errors

public enum TatwoDocProjectionErrorV1: Error, LocalizedError, Equatable, Sendable {
  case emptyLogicalName
  case emptyBody
  case emptySourceRevision
  /// 2026-07-23 scope ruling: threads / .thread paths are out of phase-1 sync.
  case threadsSourceForbidden(detail: String)
  case privatePathInHeader
  case invalidProjectedPayload(String)

  public var errorDescription: String? {
    switch self {
    case .emptyLogicalName:
      "doc projection logicalName must be non-empty"
    case .emptyBody:
      "doc projection source body must be non-empty"
    case .emptySourceRevision:
      "doc projection sourceRevision (commit stamp) must be non-empty"
    case let .threadsSourceForbidden(detail):
      "threads sources are excluded from Domain Data Sync phase-1 (2026-07-23): \(detail)"
    case .privatePathInHeader:
      "projection header must not contain private absolute paths"
    case let .invalidProjectedPayload(detail):
      "invalid projected payload: \(detail)"
    }
  }
}

// MARK: - Source input

/// One governance document source to project. Paths are injection-only and
/// never appear in the emitted header (privacy gate).
public struct TatwoDocProjectionSourceV1: Sendable, Equatable {
  public let logicalName: String
  /// Source body bytes as UTF-8 text (canonical content under hash).
  public let body: String
  /// Source commit / revision stamp (opaque string; usually full git SHA).
  public let sourceRevision: String
  /// Optional path used **only** for threads exclusion checks. Never written into header.
  public let sourcePathForScopeCheck: String?

  public init(
    logicalName: String,
    body: String,
    sourceRevision: String,
    sourcePathForScopeCheck: String? = nil
  ) {
    self.logicalName = logicalName
    self.body = body
    self.sourceRevision = sourceRevision
    self.sourcePathForScopeCheck = sourcePathForScopeCheck
  }
}

// MARK: - Projected document

public struct TatwoProjectedDocV1: Sendable, Equatable, Codable {
  public static let schemaName = "TatwoProjectedDocV1"

  public let schema: String
  public let logicalName: String
  /// Lowercase hex SHA-256 of UTF-8 source body (no `sha256:` prefix).
  public let sourceHash: String
  public let sourceRevision: String
  public let projectedAt: Date
  /// Auto-injected read-only notice (logicalName + hash12; no private abs paths).
  public let header: String
  /// Source body as projected (receiver edits here → tampered).
  public let body: String

  public init(
    schema: String = TatwoProjectedDocV1.schemaName,
    logicalName: String,
    sourceHash: String,
    sourceRevision: String,
    projectedAt: Date,
    header: String,
    body: String
  ) {
    self.schema = schema
    self.logicalName = logicalName
    self.sourceHash = sourceHash.lowercased()
    self.sourceRevision = sourceRevision
    self.projectedAt = projectedAt
    self.header = header
    self.body = body
  }

  /// Full on-disk projection text: machine header + human notice + body.
  public var renderedFileText: String {
    TatwoDocProjectionV1.renderFile(from: self)
  }
}

// MARK: - Verify status (three-state)

/// Three-state verify result for projected doc vs live source.
/// - `inSync`: hash + revision match; local body intact.
/// - `stale(sourceMoved:)`: projection still self-consistent but source advanced.
/// - `tampered(localEdited:)`: local projection body/header no longer matches claimed hash.
public enum TatwoDocProjectionVerifyStatusV1: Sendable, Equatable {
  case inSync
  case stale(sourceMoved: Bool)
  case tampered(localEdited: Bool)

  public var isInSync: Bool {
    if case .inSync = self { return true }
    return false
  }

  public var wireLabel: String {
    switch self {
    case .inSync: return "inSync"
    case .stale: return "stale(sourceMoved)"
    case .tampered: return "tampered(localEdited)"
    }
  }
}

// MARK: - Projector (one-way)

/// Governance document read-only projector (Domain Data Sync Plane · S1).
///
/// Public surface is intentionally one-way:
/// - `project(sources:)` → produce projections
/// - `verify(projected:against:)` → three-state check
///
/// There is **no** `writeBack`, `unproject`, `pushToSource`, or reverse merge API.
public enum TatwoDocProjectionV1 {
  public static let schemaName = "TatwoDocProjectionV1"
  public static let fileMarker = "tatwo-doc-projection-v1"
  public static let headerHashPrefixLength = 12

  /// Path fragments that must never enter phase-1 doc projection
  /// (2026-07-23: threads excluded from Domain Data Sync).
  public static let forbiddenPathTokens: [String] = ["threads", ".thread"]

  // MARK: Project

  /// Project each source into a read-only `TatwoProjectedDocV1`.
  /// Throws on empty fields, threads-path sources, or privacy-header failure.
  public static func project(
    sources: [TatwoDocProjectionSourceV1],
    projectedAt: Date = Date()
  ) throws -> [TatwoProjectedDocV1] {
    try sources.map { try projectOne($0, projectedAt: projectedAt) }
  }

  public static func projectOne(
    _ source: TatwoDocProjectionSourceV1,
    projectedAt: Date = Date()
  ) throws -> TatwoProjectedDocV1 {
    let logical = source.logicalName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !logical.isEmpty else { throw TatwoDocProjectionErrorV1.emptyLogicalName }
    guard !source.body.isEmpty else { throw TatwoDocProjectionErrorV1.emptyBody }
    let revision = source.sourceRevision.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !revision.isEmpty else { throw TatwoDocProjectionErrorV1.emptySourceRevision }

    try rejectThreadsIfNeeded(
      logicalName: logical,
      sourcePath: source.sourcePathForScopeCheck)

    let hash = sha256Hex(of: source.body)
    let header = makeHeader(logicalName: logical, sourceHash: hash)
    try assertHeaderPrivacy(header)

    return TatwoProjectedDocV1(
      logicalName: logical,
      sourceHash: hash,
      sourceRevision: revision,
      projectedAt: projectedAt,
      header: header,
      body: source.body)
  }

  // MARK: Verify

  /// Compare a projected doc against a live source.
  ///
  /// Order (hard):
  /// 1. Local integrity: `sha256(projected.body) == projected.sourceHash` and
  ///    header still matches logicalName/hash12. Fail → `tampered(localEdited: true)`.
  /// 2. Source drift: live hash/revision differ → `stale(sourceMoved: true)`.
  /// 3. Else → `inSync`.
  ///
  /// Does **not** write anything back to the source.
  public static func verify(
    projected: TatwoProjectedDocV1,
    against source: TatwoDocProjectionSourceV1
  ) -> TatwoDocProjectionVerifyStatusV1 {
    if !isLocallyIntact(projected) {
      return .tampered(localEdited: true)
    }

    let liveHash = sha256Hex(of: source.body)
    let liveRevision = source.sourceRevision.trimmingCharacters(in: .whitespacesAndNewlines)
    if liveHash != projected.sourceHash || liveRevision != projected.sourceRevision {
      return .stale(sourceMoved: true)
    }
    return .inSync
  }

  /// Parse a rendered projection file back into `TatwoProjectedDocV1`.
  public static func parseRenderedFile(_ text: String) throws -> TatwoProjectedDocV1 {
    let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
    guard normalized.hasPrefix("<!-- \(fileMarker)") || normalized.hasPrefix("<!--\(fileMarker)")
    else {
      throw TatwoDocProjectionErrorV1.invalidProjectedPayload("missing \(fileMarker) marker")
    }
    guard let endRange = normalized.range(of: "-->") else {
      throw TatwoDocProjectionErrorV1.invalidProjectedPayload("unclosed header comment")
    }
    let headerBlock = String(normalized[..<endRange.upperBound])
    let rest = String(normalized[endRange.upperBound...])
    let body: String
    if rest.hasPrefix("\n") {
      body = String(rest.dropFirst())
    } else {
      body = rest
    }

    func field(_ key: String) throws -> String {
      // Lines like: # logicalName: value   OR   logicalName: value
      let pattern = #"(?m)^(?:#\s*)?"# + NSRegularExpression.escapedPattern(for: key)
        + #"\s*:\s*(.+?)\s*$"#
      guard let regex = try? NSRegularExpression(pattern: pattern) else {
        throw TatwoDocProjectionErrorV1.invalidProjectedPayload("regex failure for \(key)")
      }
      let ns = headerBlock as NSString
      let range = NSRange(location: 0, length: ns.length)
      guard let match = regex.firstMatch(in: headerBlock, range: range),
        match.numberOfRanges >= 2,
        let swiftRange = Range(match.range(at: 1), in: headerBlock)
      else {
        throw TatwoDocProjectionErrorV1.invalidProjectedPayload("missing field \(key)")
      }
      return String(headerBlock[swiftRange])
    }

    let logicalName = try field("logicalName")
    let sourceHash = try field("sourceHash").lowercased()
    let sourceRevision = try field("sourceRevision")
    let projectedAtRaw = try field("projectedAt")
    let headerNotice = try field("notice")

    guard sourceHash.count == 64,
      sourceHash.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdef").contains($0) })
    else {
      throw TatwoDocProjectionErrorV1.invalidProjectedPayload("sourceHash must be 64 hex chars")
    }

    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    var projectedAt = formatter.date(from: projectedAtRaw)
    if projectedAt == nil {
      formatter.formatOptions = [.withInternetDateTime]
      projectedAt = formatter.date(from: projectedAtRaw)
    }
    guard let projectedAt else {
      throw TatwoDocProjectionErrorV1.invalidProjectedPayload("projectedAt not ISO-8601")
    }

    let doc = TatwoProjectedDocV1(
      logicalName: logicalName,
      sourceHash: sourceHash,
      sourceRevision: sourceRevision,
      projectedAt: projectedAt,
      header: headerNotice,
      body: body)
    try assertHeaderPrivacy(doc.header)
    return doc
  }

  // MARK: Header / privacy / hash

  /// Human-readable notice: logicalName + first 12 hash chars. No private abs paths.
  public static func makeHeader(logicalName: String, sourceHash: String) -> String {
    let hash12 = String(sourceHash.prefix(headerHashPrefixLength))
    return "此為唯讀投影，權威在 \(logicalName)@\(hash12)"
  }

  public static func sha256Hex(of text: String) -> String {
    let digest = SHA256.hash(data: Data(text.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
  }

  public static func isThreadsForbiddenPath(_ path: String) -> Bool {
    let lowered = path.lowercased()
    // Normalize separators for token search.
    let normalized = lowered.replacingOccurrences(of: "\\", with: "/")
    for token in forbiddenPathTokens {
      if normalized.contains(token) { return true }
    }
    return false
  }

  public static func renderFile(from doc: TatwoProjectedDocV1) -> String {
    let iso = iso8601(doc.projectedAt)
    // Machine-parseable HTML comment + human notice field. Body follows after -->.
    // Never embeds absolute source paths.
    var lines: [String] = []
    lines.append("<!-- \(fileMarker)")
    lines.append("schema: \(TatwoProjectedDocV1.schemaName)")
    lines.append("logicalName: \(doc.logicalName)")
    lines.append("sourceHash: \(doc.sourceHash)")
    lines.append("sourceRevision: \(doc.sourceRevision)")
    lines.append("projectedAt: \(iso)")
    lines.append("notice: \(doc.header)")
    lines.append("-->")
    // Preserve source body exactly (may itself start with markdown).
    return lines.joined(separator: "\n") + "\n" + doc.body
  }

  // MARK: - Private

  private static func rejectThreadsIfNeeded(logicalName: String, sourcePath: String?) throws {
    if isThreadsForbiddenPath(logicalName) {
      throw TatwoDocProjectionErrorV1.threadsSourceForbidden(
        detail: "logicalName contains forbidden threads token")
    }
    if let path = sourcePath, isThreadsForbiddenPath(path) {
      // Detail uses only basename-ish hint tokens — no private abs path echo required.
      throw TatwoDocProjectionErrorV1.threadsSourceForbidden(
        detail: "source path contains threads/.thread (phase-1 exclusion)")
    }
  }

  private static func isLocallyIntact(_ projected: TatwoProjectedDocV1) -> Bool {
    let recomputed = sha256Hex(of: projected.body)
    if recomputed != projected.sourceHash { return false }
    let expectedHeader = makeHeader(
      logicalName: projected.logicalName,
      sourceHash: projected.sourceHash)
    if projected.header != expectedHeader { return false }
    // Privacy must hold on stored header.
    if containsPrivateAbsolutePath(projected.header) { return false }
    return true
  }

  private static func assertHeaderPrivacy(_ header: String) throws {
    if containsPrivateAbsolutePath(header) {
      throw TatwoDocProjectionErrorV1.privatePathInHeader
    }
  }

  /// Privacy gate patterns aligned with `TatwoPrivacyRedactor` (must not regress).
  public static func containsPrivateAbsolutePath(_ text: String) -> Bool {
    let patterns = [
      #"/Users/[^ \n\"'`<>]+"#,
      #"/Volumes/[^ \n\"'`<>]+"#,
      #"~/\.codex/[^\s\"'`<>]+"#,
      #"\$HOME/[^\s\"'`<>]+"#,
    ]
    for pattern in patterns {
      if text.range(of: pattern, options: .regularExpression) != nil {
        return true
      }
    }
    return false
  }

  private static func iso8601(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: date)
  }
}
