import CryptoKit
import Foundation

public enum TatwoContextCompressionKind: String, Codable, Sendable, CaseIterable {
  case auto
  case json
  case log
  case code
  case text
}

public struct TatwoContextCompressionPolicy: Codable, Sendable, Equatable {
  public let schema: String
  public var maxCompressedCharacters: Int
  public var maxPreservedDiagnosticLines: Int
  public var maxLineCharacters: Int
  public var cacheOriginal: Bool
  public var failOnSensitiveContent: Bool
  public var redactShareableOutput: Bool

  public init(
    schema: String = "TatwoContextCompressionPolicyV1",
    maxCompressedCharacters: Int = 2_400,
    maxPreservedDiagnosticLines: Int = 40,
    maxLineCharacters: Int = 240,
    cacheOriginal: Bool = true,
    failOnSensitiveContent: Bool = true,
    redactShareableOutput: Bool = true
  ) {
    self.schema = schema
    self.maxCompressedCharacters = max(600, maxCompressedCharacters)
    self.maxPreservedDiagnosticLines = max(4, maxPreservedDiagnosticLines)
    self.maxLineCharacters = max(80, maxLineCharacters)
    self.cacheOriginal = cacheOriginal
    self.failOnSensitiveContent = failOnSensitiveContent
    self.redactShareableOutput = redactShareableOutput
  }

  public static let `default` = TatwoContextCompressionPolicy()
}

public struct TatwoContextCompressionReceipt: Codable, Sendable, Equatable, Identifiable {
  public let schema: String
  public let id: String
  public let createdAt: Date
  public let kind: TatwoContextCompressionKind
  public let sourceLabel: String
  public let originalSHA256: String
  public let originalBytes: Int
  public let compressedBytes: Int
  public let estimatedOriginalTokens: Int
  public let estimatedCompressedTokens: Int
  public let reductionRatio: Double
  public let reversible: Bool
  public let cacheDirectory: String?
  public let originalPath: String?
  public let compressedPath: String?
  public let requiredRetrieveTool: String
  public let preservedSignals: [String]
  public let warnings: [String]
  public let compressedText: String

  public init(
    schema: String = "TatwoContextCompressionReceiptV1",
    id: String,
    createdAt: Date = Date(),
    kind: TatwoContextCompressionKind,
    sourceLabel: String,
    originalSHA256: String,
    originalBytes: Int,
    compressedBytes: Int,
    estimatedOriginalTokens: Int,
    estimatedCompressedTokens: Int,
    reductionRatio: Double,
    reversible: Bool,
    cacheDirectory: String?,
    originalPath: String?,
    compressedPath: String?,
    requiredRetrieveTool: String = "tatwo.context.retrieve",
    preservedSignals: [String],
    warnings: [String],
    compressedText: String
  ) {
    self.schema = schema
    self.id = id
    self.createdAt = createdAt
    self.kind = kind
    self.sourceLabel = TatwoPrivacyRedactor.redacted(sourceLabel)
    self.originalSHA256 = originalSHA256
    self.originalBytes = originalBytes
    self.compressedBytes = compressedBytes
    self.estimatedOriginalTokens = estimatedOriginalTokens
    self.estimatedCompressedTokens = estimatedCompressedTokens
    self.reductionRatio = reductionRatio
    self.reversible = reversible
    self.cacheDirectory = cacheDirectory.map(TatwoPrivacyRedactor.redacted)
    self.originalPath = originalPath.map(TatwoPrivacyRedactor.redacted)
    self.compressedPath = compressedPath.map(TatwoPrivacyRedactor.redacted)
    self.requiredRetrieveTool = requiredRetrieveTool
    self.preservedSignals = preservedSignals.map(TatwoPrivacyRedactor.redacted)
    self.warnings = warnings.map(TatwoPrivacyRedactor.redacted)
    self.compressedText = compressedText
  }
}

public struct TatwoContextRetrieveResult: Codable, Sendable, Equatable {
  public let schema: String
  public let id: String
  public let originalSHA256: String
  public let originalBytes: Int
  public let text: String

  public init(
    schema: String = "TatwoContextRetrieveResultV1",
    id: String,
    originalSHA256: String,
    originalBytes: Int,
    text: String
  ) {
    self.schema = schema
    self.id = id
    self.originalSHA256 = originalSHA256
    self.originalBytes = originalBytes
    self.text = text
  }
}

public struct TatwoContextCompressionStats: Codable, Sendable, Equatable {
  public let schema: String
  public let receiptCount: Int
  public let originalBytes: Int
  public let compressedBytes: Int
  public let estimatedOriginalTokens: Int
  public let estimatedCompressedTokens: Int
  public let averageReductionRatio: Double
  public let byKind: [String: Int]

  public init(
    schema: String = "TatwoContextCompressionStatsV1",
    receiptCount: Int,
    originalBytes: Int,
    compressedBytes: Int,
    estimatedOriginalTokens: Int,
    estimatedCompressedTokens: Int,
    averageReductionRatio: Double,
    byKind: [String: Int]
  ) {
    self.schema = schema
    self.receiptCount = receiptCount
    self.originalBytes = originalBytes
    self.compressedBytes = compressedBytes
    self.estimatedOriginalTokens = estimatedOriginalTokens
    self.estimatedCompressedTokens = estimatedCompressedTokens
    self.averageReductionRatio = averageReductionRatio
    self.byKind = byKind
  }
}

public enum TatwoContextCompressionError: Error, LocalizedError, Sendable, Equatable {
  case sensitiveContent([String])
  case missingOriginal(String)
  case invalidReceipt(String)

  public var errorDescription: String? {
    switch self {
    case .sensitiveContent(let findings):
      return "Context compression rejected sensitive content: \(findings.joined(separator: ","))"
    case .missingOriginal(let id):
      return "Original context not found for \(id)"
    case .invalidReceipt(let path):
      return "Invalid context compression receipt at \(path)"
    }
  }
}

public enum TatwoContextCompressionFactory {
  public static func cacheRoot(root: URL) -> URL {
    root.appendingPathComponent(".tatwo-ultrawork/context-cache", isDirectory: true)
  }

  public static func policy() -> TatwoContextCompressionPolicy {
    .default
  }

  public static func compress(
    text: String,
    kind requestedKind: TatwoContextCompressionKind = .auto,
    sourceLabel: String = "inline-context",
    runID: String = "default",
    root: URL,
    policy: TatwoContextCompressionPolicy = .default
  ) throws -> TatwoContextCompressionReceipt {
    let raw = text.trimmingCharacters(in: .newlines)
    let sensitiveFindings = sensitiveContentFindings(in: raw)
    if policy.failOnSensitiveContent && !sensitiveFindings.isEmpty {
      throw TatwoContextCompressionError.sensitiveContent(sensitiveFindings)
    }

    let kind = requestedKind == .auto ? inferKind(raw) : requestedKind
    let sha = sha256Hex(Data(raw.utf8))
    let id = "ctx-\(String(sha.prefix(12)))"
    let compression = compressedSummary(
      text: raw,
      kind: kind,
      id: id,
      sha: sha,
      policy: policy)
    let shareableText =
      policy.redactShareableOutput
      ? TatwoPrivacyRedactor.redacted(compression.text)
      : compression.text

    var cacheDir: URL?
    var originalURL: URL?
    var compressedURL: URL?
    if policy.cacheOriginal {
      let dir = cacheRoot(root: root)
        .appendingPathComponent(safePathComponent(runID), isDirectory: true)
        .appendingPathComponent(id, isDirectory: true)
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      let original = dir.appendingPathComponent("original.txt")
      let compressed = dir.appendingPathComponent("compressed.md")
      try Data(raw.utf8).write(to: original, options: [.atomic])
      try Data(shareableText.utf8).write(to: compressed, options: [.atomic])
      cacheDir = dir
      originalURL = original
      compressedURL = compressed
    }

    let originalBytes = Data(raw.utf8).count
    let compressedBytes = Data(shareableText.utf8).count
    let originalTokens = estimateTokens(raw)
    let compressedTokens = estimateTokens(shareableText)
    let ratio =
      originalTokens > 0
      ? max(0, min(1, 1 - (Double(compressedTokens) / Double(originalTokens))))
      : 0

    let receipt = TatwoContextCompressionReceipt(
      id: id,
      kind: kind,
      sourceLabel: sourceLabel,
      originalSHA256: sha,
      originalBytes: originalBytes,
      compressedBytes: compressedBytes,
      estimatedOriginalTokens: originalTokens,
      estimatedCompressedTokens: compressedTokens,
      reductionRatio: ratio,
      reversible: policy.cacheOriginal,
      cacheDirectory: cacheDir?.path,
      originalPath: originalURL?.path,
      compressedPath: compressedURL?.path,
      preservedSignals: compression.signals,
      warnings: sensitiveFindings.map { "sensitive-marker-redacted:\($0)" } + compression.warnings,
      compressedText: shareableText)

    if let cacheDir {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      encoder.dateEncodingStrategy = .iso8601
      try encoder.encode(receipt)
        .write(to: cacheDir.appendingPathComponent("receipt.json"), options: [.atomic])
    }
    return receipt
  }

  public static func retrieve(id: String, root: URL, runID: String? = nil) throws -> TatwoContextRetrieveResult {
    guard let dir = try findCacheDirectory(id: id, root: root, runID: runID) else {
      throw TatwoContextCompressionError.missingOriginal(id)
    }
    let receiptURL = dir.appendingPathComponent("receipt.json")
    let originalURL = dir.appendingPathComponent("original.txt")
    guard FileManager.default.fileExists(atPath: receiptURL.path),
      FileManager.default.fileExists(atPath: originalURL.path)
    else {
      throw TatwoContextCompressionError.missingOriginal(id)
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let receipt = try decoder.decode(TatwoContextCompressionReceipt.self, from: Data(contentsOf: receiptURL))
    let data = try Data(contentsOf: originalURL)
    let actual = sha256Hex(data)
    guard actual == receipt.originalSHA256 else {
      throw TatwoContextCompressionError.invalidReceipt(receiptURL.path)
    }
    return TatwoContextRetrieveResult(
      id: receipt.id,
      originalSHA256: actual,
      originalBytes: data.count,
      text: String(decoding: data, as: UTF8.self))
  }

  public static func stats(root: URL) throws -> TatwoContextCompressionStats {
    let receipts = try allReceipts(root: root)
    let originalBytes = receipts.reduce(0) { $0 + $1.originalBytes }
    let compressedBytes = receipts.reduce(0) { $0 + $1.compressedBytes }
    let originalTokens = receipts.reduce(0) { $0 + $1.estimatedOriginalTokens }
    let compressedTokens = receipts.reduce(0) { $0 + $1.estimatedCompressedTokens }
    var byKind: [String: Int] = [:]
    for receipt in receipts {
      byKind[receipt.kind.rawValue, default: 0] += 1
    }
    let average =
      receipts.isEmpty
      ? 0
      : receipts.reduce(0) { $0 + $1.reductionRatio } / Double(receipts.count)
    return TatwoContextCompressionStats(
      receiptCount: receipts.count,
      originalBytes: originalBytes,
      compressedBytes: compressedBytes,
      estimatedOriginalTokens: originalTokens,
      estimatedCompressedTokens: compressedTokens,
      averageReductionRatio: average,
      byKind: byKind)
  }

  private struct CompressionResult {
    let text: String
    let signals: [String]
    let warnings: [String]
  }

  private static func compressedSummary(
    text: String,
    kind: TatwoContextCompressionKind,
    id: String,
    sha: String,
    policy: TatwoContextCompressionPolicy
  ) -> CompressionResult {
    let body: CompressionResult
    switch kind {
    case .auto:
      body = compressedSummary(text: text, kind: inferKind(text), id: id, sha: sha, policy: policy)
    case .json:
      body = compressJSON(text, policy: policy)
    case .log:
      body = compressLog(text, policy: policy)
    case .code:
      body = compressCode(text, policy: policy)
    case .text:
      body = compressText(text, policy: policy)
    }

    var header = """
      # TATWO Context Compression
      id: \(id)
      kind: \(kind.rawValue)
      original_sha256: \(sha)
      retrieve: tatwo-ultrawork context retrieve --id \(id) --json

      """
    header += body.text
    let limited = limit(header, to: policy.maxCompressedCharacters)
    let warnings =
      header.count > limited.count
      ? body.warnings + ["compressed summary truncated to \(policy.maxCompressedCharacters) characters"]
      : body.warnings
    return CompressionResult(text: limited, signals: body.signals, warnings: warnings)
  }

  private static func compressJSON(_ text: String, policy: TatwoContextCompressionPolicy) -> CompressionResult {
    guard let data = text.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data)
    else {
      return compressText(text, policy: policy)
    }
    var lines = ["## JSON shape"]
    lines.append(contentsOf: jsonShapeLines(object, prefix: "$", depth: 0, maxDepth: 3).prefix(80))
    let signalLines = lines.filter {
      $0.range(of: #"(?i)(error|fatal|warn|status|message|reason|exception|failed|path)"#, options: .regularExpression) != nil
    }
    if !signalLines.isEmpty {
      lines.append("\n## Preserved diagnostic fields")
      lines.append(contentsOf: signalLines.prefix(policy.maxPreservedDiagnosticLines))
    }
    return CompressionResult(
      text: lines.joined(separator: "\n"),
      signals: signalLines.prefix(12).map { String($0) },
      warnings: [])
  }

  private static func compressLog(_ text: String, policy: TatwoContextCompressionPolicy) -> CompressionResult {
    let lines = text.components(separatedBy: .newlines)
    let diagnostics = lines.filter {
      $0.range(of: #"(?i)(fatal|error|warn|exception|traceback|failed|panic|segmentation|denied)"#, options: .regularExpression) != nil
    }
    var output = [
      "## Log summary",
      "line_count: \(lines.count)",
      "diagnostic_line_count: \(diagnostics.count)",
      "",
      "## First lines",
    ]
    output.append(contentsOf: lines.prefix(8).map { trimLine($0, policy: policy) })
    if !diagnostics.isEmpty {
      output.append("\n## Preserved diagnostics")
      output.append(contentsOf: diagnostics.prefix(policy.maxPreservedDiagnosticLines).map { trimLine($0, policy: policy) })
    }
    output.append("\n## Last lines")
    output.append(contentsOf: lines.suffix(8).map { trimLine($0, policy: policy) })
    return CompressionResult(
      text: output.joined(separator: "\n"),
      signals: diagnostics.prefix(12).map { trimLine($0, policy: policy) },
      warnings: diagnostics.count > policy.maxPreservedDiagnosticLines
        ? ["diagnostic lines truncated: \(diagnostics.count) > \(policy.maxPreservedDiagnosticLines)"]
        : [])
  }

  private static func compressCode(_ text: String, policy: TatwoContextCompressionPolicy) -> CompressionResult {
    let lines = text.components(separatedBy: .newlines)
    let signatures = lines.filter {
      $0.range(
        of: #"^\s*(public\s+|private\s+|internal\s+|static\s+|final\s+|class\s+|struct\s+|enum\s+|func\s+|let\s+|var\s+|import\s+)"#,
        options: .regularExpression) != nil
    }
    let markers = lines.filter {
      $0.range(of: #"(?i)(todo|fixme|fatal|error|warning|throw|catch|guard\s+let)"#, options: .regularExpression) != nil
    }
    var output = [
      "## Code outline",
      "line_count: \(lines.count)",
      "",
      "## Imports / declarations",
    ]
    output.append(contentsOf: signatures.prefix(80).map { trimLine($0, policy: policy) })
    if !markers.isEmpty {
      output.append("\n## Risk markers")
      output.append(contentsOf: markers.prefix(policy.maxPreservedDiagnosticLines).map { trimLine($0, policy: policy) })
    }
    return CompressionResult(
      text: output.joined(separator: "\n"),
      signals: markers.prefix(12).map { trimLine($0, policy: policy) },
      warnings: signatures.count > 80 ? ["declarations truncated: \(signatures.count) > 80"] : [])
  }

  private static func compressText(_ text: String, policy: TatwoContextCompressionPolicy) -> CompressionResult {
    let lines = text.components(separatedBy: .newlines)
    let headings = lines.filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
    let bullets = lines.filter {
      let trimmed = $0.trimmingCharacters(in: .whitespaces)
      return trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.range(of: #"^\d+\."#, options: .regularExpression) != nil
    }
    let diagnostics = lines.filter {
      $0.range(of: #"(?i)(must|forbidden|fail|error|risk|required|receipt|gate|blocked|rollback)"#, options: .regularExpression) != nil
    }
    var output = ["## Text summary", "line_count: \(lines.count)"]
    if !headings.isEmpty {
      output.append("\n## Headings")
      output.append(contentsOf: headings.prefix(40).map { trimLine($0, policy: policy) })
    }
    if !diagnostics.isEmpty {
      output.append("\n## Preserved requirements / risks")
      output.append(contentsOf: diagnostics.prefix(policy.maxPreservedDiagnosticLines).map { trimLine($0, policy: policy) })
    }
    if !bullets.isEmpty {
      output.append("\n## Representative bullets")
      output.append(contentsOf: bullets.prefix(40).map { trimLine($0, policy: policy) })
    }
    output.append("\n## Opening / closing context")
    output.append(contentsOf: lines.prefix(6).map { trimLine($0, policy: policy) })
    output.append("...")
    output.append(contentsOf: lines.suffix(6).map { trimLine($0, policy: policy) })
    return CompressionResult(
      text: output.joined(separator: "\n"),
      signals: diagnostics.prefix(12).map { trimLine($0, policy: policy) },
      warnings: [])
  }

  private static func inferKind(_ text: String) -> TatwoContextCompressionKind {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if let data = trimmed.data(using: .utf8),
      (try? JSONSerialization.jsonObject(with: data)) != nil
    {
      return .json
    }
    if trimmed.range(of: #"(?m)^\s*(import|class|struct|enum|func|const|let|var|def|package)\b"#, options: .regularExpression) != nil {
      return .code
    }
    if trimmed.range(of: #"(?i)(fatal|error|warn|traceback|exception|failed|panic)"#, options: .regularExpression) != nil
      || trimmed.range(of: #"(?m)^\d{4}-\d{2}-\d{2}[T\s]"#, options: .regularExpression) != nil
    {
      return .log
    }
    return .text
  }

  private static func sensitiveContentFindings(in text: String) -> [String] {
    let checks: [(String, String)] = [
      (#"(?i)\b(access[_-]?token|refresh[_-]?token|id[_-]?token|auth\.json|session[_ -]?cookie|cookie)\b"#, "auth/session token marker"),
      (#"(?i)\b(api[_-]?key|secret[_-]?key|private[_-]?key|service[_-]?role)\b"#, "secret key marker"),
      (#"sk-[A-Za-z0-9_\-]{10,}"#, "OpenAI-style API key"),
      (#"-----BEGIN (RSA |OPENSSH |EC |DSA )?PRIVATE KEY-----"#, "private key block"),
    ]
    return checks.compactMap { pattern, label in
      text.range(of: pattern, options: .regularExpression) == nil ? nil : label
    }
  }

  private static func jsonShapeLines(_ value: Any, prefix: String, depth: Int, maxDepth: Int) -> [String] {
    if depth > maxDepth { return ["\(prefix): …"] }
    switch value {
    case let object as [String: Any]:
      var lines = ["\(prefix): object keys=\(object.keys.sorted().joined(separator: ","))"]
      for key in object.keys.sorted().prefix(24) {
        if let child = object[key] {
          lines.append(contentsOf: jsonShapeLines(child, prefix: "\(prefix).\(key)", depth: depth + 1, maxDepth: maxDepth))
        }
      }
      return lines
    case let array as [Any]:
      var lines = ["\(prefix): array count=\(array.count)"]
      if let first = array.first {
        lines.append(contentsOf: jsonShapeLines(first, prefix: "\(prefix)[0]", depth: depth + 1, maxDepth: maxDepth))
      }
      return lines
    case let string as String:
      return ["\(prefix): string \(string.count) chars \(preview(string))"]
    case let number as NSNumber:
      return ["\(prefix): number/bool \(number)"]
    default:
      return ["\(prefix): \(type(of: value))"]
    }
  }

  private static func allReceipts(root: URL) throws -> [TatwoContextCompressionReceipt] {
    let rootURL = cacheRoot(root: root)
    guard FileManager.default.fileExists(atPath: rootURL.path) else { return [] }
    let enumerator = FileManager.default.enumerator(
      at: rootURL,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsHiddenFiles])
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    var receipts: [TatwoContextCompressionReceipt] = []
    while let url = enumerator?.nextObject() as? URL {
      guard url.lastPathComponent == "receipt.json" else { continue }
      if let receipt = try? decoder.decode(TatwoContextCompressionReceipt.self, from: Data(contentsOf: url)) {
        receipts.append(receipt)
      }
    }
    return receipts
  }

  private static func findCacheDirectory(id: String, root: URL, runID: String?) throws -> URL? {
    let rootURL = cacheRoot(root: root)
    if let runID {
      let dir = rootURL.appendingPathComponent(safePathComponent(runID), isDirectory: true)
        .appendingPathComponent(safePathComponent(id), isDirectory: true)
      return FileManager.default.fileExists(atPath: dir.path) ? dir : nil
    }
    guard FileManager.default.fileExists(atPath: rootURL.path) else { return nil }
    let enumerator = FileManager.default.enumerator(
      at: rootURL,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsHiddenFiles])
    while let url = enumerator?.nextObject() as? URL {
      if url.lastPathComponent == id,
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
      {
        return url
      }
    }
    return nil
  }

  private static func trimLine(_ line: String, policy: TatwoContextCompressionPolicy) -> String {
    limit(line.trimmingCharacters(in: .whitespaces), to: policy.maxLineCharacters)
  }

  private static func limit(_ value: String, to maxCharacters: Int) -> String {
    guard value.count > maxCharacters else { return value }
    let index = value.index(value.startIndex, offsetBy: max(0, maxCharacters - 16))
    return String(value[..<index]) + "\n…[truncated]"
  }

  private static func preview(_ value: String) -> String {
    let trimmed = value.replacingOccurrences(of: "\n", with: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "" }
    return "\"\(limit(trimmed, to: 80))\""
  }

  private static func estimateTokens(_ text: String) -> Int {
    max(1, Int(ceil(Double(text.count) / 4.0)))
  }

  private static func safePathComponent(_ value: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
    let filtered = String(value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
    return filtered.isEmpty ? "default" : filtered
  }

  private static func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
