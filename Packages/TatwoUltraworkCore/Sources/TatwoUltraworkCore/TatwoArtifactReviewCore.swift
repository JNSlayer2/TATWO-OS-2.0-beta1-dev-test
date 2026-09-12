import CryptoKit
import Foundation

public enum TatwoArtifactReviewHasher {
  public static func sha256(_ content: String) -> String {
    sha256(Data(content.utf8))
  }

  public static func sha256(_ content: Data) -> String {
    SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined()
  }
}

public struct TatwoArtifactReviewOriginalFileV1: Codable, Sendable, Equatable {
  public let schema: String
  public let artifactID: String
  public let sourceRelativePath: String
  public let content: String
  public let contentSHA256: String

  public init(
    schema: String = "TatwoArtifactReviewOriginalFileV1",
    artifactID: String,
    sourceRelativePath: String,
    content: String
  ) {
    self.schema = schema
    self.artifactID = artifactID
    self.sourceRelativePath = sourceRelativePath
    self.content = content
    self.contentSHA256 = TatwoArtifactReviewHasher.sha256(content)
  }
}

public struct TatwoArtifactReviewRenderedContentV1: Codable, Sendable, Equatable {
  public let schema: String
  public let renderID: String
  public let artifactID: String
  public let renderer: String
  public let content: String
  public let contentSHA256: String
  public let pageCount: Int?

  public init(
    schema: String = "TatwoArtifactReviewRenderedContentV1",
    renderID: String,
    artifactID: String,
    renderer: String,
    content: String,
    pageCount: Int? = nil
  ) {
    self.schema = schema
    self.renderID = renderID
    self.artifactID = artifactID
    self.renderer = renderer
    self.content = content
    self.contentSHA256 = TatwoArtifactReviewHasher.sha256(content)
    self.pageCount = pageCount.map { max(0, $0) }
  }
}

public struct TatwoArtifactReviewExportHashV1: Codable, Sendable, Equatable {
  public let schema: String
  public let exportID: String
  public let artifactID: String
  public let mediaType: String
  public let byteCount: Int
  public let sha256: String

  public init(
    schema: String = "TatwoArtifactReviewExportHashV1",
    exportID: String,
    artifactID: String,
    mediaType: String,
    content: Data
  ) {
    self.schema = schema
    self.exportID = exportID
    self.artifactID = artifactID
    self.mediaType = mediaType
    self.byteCount = content.count
    self.sha256 = TatwoArtifactReviewHasher.sha256(content)
  }
}

public enum TatwoArtifactReviewDiffKindV1:
  String,
  Codable,
  Sendable,
  CaseIterable,
  Equatable
{
  case insert
  case delete
  case replace
}

public struct TatwoArtifactReviewLineRangeV1: Codable, Sendable, Equatable {
  public let startLine: Int
  public let lineCount: Int

  public init(startLine: Int, lineCount: Int) {
    self.startLine = max(1, startLine)
    self.lineCount = max(0, lineCount)
  }
}

public struct TatwoArtifactReviewDiffHunkV1:
  Codable,
  Sendable,
  Identifiable,
  Equatable
{
  public let id: String
  public let kind: TatwoArtifactReviewDiffKindV1
  public let originalRange: TatwoArtifactReviewLineRangeV1
  public let modifiedRange: TatwoArtifactReviewLineRangeV1
  public let beforeContent: String
  public let afterContent: String
  public let beforeSHA256: String
  public let afterSHA256: String

  public init(
    id: String,
    kind: TatwoArtifactReviewDiffKindV1,
    originalRange: TatwoArtifactReviewLineRangeV1,
    modifiedRange: TatwoArtifactReviewLineRangeV1,
    beforeContent: String,
    afterContent: String
  ) {
    self.id = id
    self.kind = kind
    self.originalRange = originalRange
    self.modifiedRange = modifiedRange
    self.beforeContent = beforeContent
    self.afterContent = afterContent
    self.beforeSHA256 = TatwoArtifactReviewHasher.sha256(beforeContent)
    self.afterSHA256 = TatwoArtifactReviewHasher.sha256(afterContent)
  }
}

public struct TatwoArtifactReviewDiffSummaryV1: Codable, Sendable, Equatable {
  public let hunkCount: Int
  public let insertedLineCount: Int
  public let deletedLineCount: Int
  public let replacementHunkCount: Int

  public init(
    hunkCount: Int,
    insertedLineCount: Int,
    deletedLineCount: Int,
    replacementHunkCount: Int
  ) {
    self.hunkCount = max(0, hunkCount)
    self.insertedLineCount = max(0, insertedLineCount)
    self.deletedLineCount = max(0, deletedLineCount)
    self.replacementHunkCount = max(0, replacementHunkCount)
  }
}

public struct TatwoArtifactReviewModificationDiffV1: Codable, Sendable, Equatable {
  public let schema: String
  public let originalSHA256: String
  public let modifiedSHA256: String
  public let hunks: [TatwoArtifactReviewDiffHunkV1]
  public let summary: TatwoArtifactReviewDiffSummaryV1

  public init(
    schema: String = "TatwoArtifactReviewModificationDiffV1",
    originalSHA256: String,
    modifiedSHA256: String,
    hunks: [TatwoArtifactReviewDiffHunkV1],
    summary: TatwoArtifactReviewDiffSummaryV1
  ) {
    self.schema = schema
    self.originalSHA256 = originalSHA256
    self.modifiedSHA256 = modifiedSHA256
    self.hunks = hunks
    self.summary = summary
  }
}

public enum TatwoArtifactReviewDiffAggregator {
  public static func diff(
    original: String,
    modified: String
  ) -> TatwoArtifactReviewModificationDiffV1 {
    let originalLines = lineTokens(original)
    let modifiedLines = lineTokens(modified)
    let difference = modifiedLines.difference(from: originalLines)

    var removedOffsets = Set<Int>()
    var insertedOffsets = Set<Int>()
    for change in difference {
      switch change {
      case let .remove(offset, _, _):
        removedOffsets.insert(offset)
      case let .insert(offset, _, _):
        insertedOffsets.insert(offset)
      }
    }

    var originalIndex = 0
    var modifiedIndex = 0
    var hunks: [TatwoArtifactReviewDiffHunkV1] = []
    var pending: PendingHunk?

    func makePending() -> PendingHunk {
      PendingHunk(
        originalStart: originalIndex + 1,
        modifiedStart: modifiedIndex + 1)
    }

    func finishPending() {
      guard let value = pending else {
        return
      }
      hunks.append(value.makeHunk(index: hunks.count))
      pending = nil
    }

    while originalIndex < originalLines.count || modifiedIndex < modifiedLines.count {
      if originalIndex < originalLines.count, removedOffsets.contains(originalIndex) {
        if pending == nil {
          pending = makePending()
        }
        pending?.beforeLines.append(originalLines[originalIndex])
        originalIndex += 1
        continue
      }

      if modifiedIndex < modifiedLines.count, insertedOffsets.contains(modifiedIndex) {
        if pending == nil {
          pending = makePending()
        }
        pending?.afterLines.append(modifiedLines[modifiedIndex])
        modifiedIndex += 1
        continue
      }

      if originalIndex < originalLines.count, modifiedIndex < modifiedLines.count {
        finishPending()
        originalIndex += 1
        modifiedIndex += 1
        continue
      }

      if originalIndex < originalLines.count {
        if pending == nil {
          pending = makePending()
        }
        pending?.beforeLines.append(originalLines[originalIndex])
        originalIndex += 1
      } else if modifiedIndex < modifiedLines.count {
        if pending == nil {
          pending = makePending()
        }
        pending?.afterLines.append(modifiedLines[modifiedIndex])
        modifiedIndex += 1
      }
    }
    finishPending()

    let summary = TatwoArtifactReviewDiffSummaryV1(
      hunkCount: hunks.count,
      insertedLineCount: hunks.reduce(0) { $0 + $1.modifiedRange.lineCount },
      deletedLineCount: hunks.reduce(0) { $0 + $1.originalRange.lineCount },
      replacementHunkCount: hunks.filter { $0.kind == .replace }.count)

    return TatwoArtifactReviewModificationDiffV1(
      originalSHA256: TatwoArtifactReviewHasher.sha256(original),
      modifiedSHA256: TatwoArtifactReviewHasher.sha256(modified),
      hunks: hunks,
      summary: summary)
  }

  private struct PendingHunk {
    let originalStart: Int
    let modifiedStart: Int
    var beforeLines: [String] = []
    var afterLines: [String] = []

    func makeHunk(index: Int) -> TatwoArtifactReviewDiffHunkV1 {
      let beforeContent = beforeLines.joined()
      let afterContent = afterLines.joined()
      let kind: TatwoArtifactReviewDiffKindV1
      if beforeLines.isEmpty {
        kind = .insert
      } else if afterLines.isEmpty {
        kind = .delete
      } else {
        kind = .replace
      }

      let canonicalID = [
        String(originalStart),
        String(modifiedStart),
        beforeContent,
        afterContent,
      ].joined(separator: "\u{1f}")
      let digest = TatwoArtifactReviewHasher.sha256(canonicalID)

      return TatwoArtifactReviewDiffHunkV1(
        id: "hunk-\(index + 1)-\(digest.prefix(16))",
        kind: kind,
        originalRange: TatwoArtifactReviewLineRangeV1(
          startLine: originalStart,
          lineCount: beforeLines.count),
        modifiedRange: TatwoArtifactReviewLineRangeV1(
          startLine: modifiedStart,
          lineCount: afterLines.count),
        beforeContent: beforeContent,
        afterContent: afterContent)
    }
  }

  private static func lineTokens(_ content: String) -> [String] {
    guard !content.isEmpty else {
      return []
    }

    let parts = content.components(separatedBy: "\n")
    return parts.enumerated().compactMap { index, part in
      if index < parts.count - 1 {
        return part + "\n"
      }
      return part.isEmpty ? nil : part
    }
  }
}

public enum TatwoArtifactReviewAnnotationTargetKindV1:
  String,
  Codable,
  Sendable,
  CaseIterable,
  Equatable
{
  case original
  case render
  case diffHunk = "diff_hunk"
}

public enum TatwoArtifactReviewAnnotationSeverityV1:
  String,
  Codable,
  Sendable,
  CaseIterable,
  Equatable
{
  case note
  case suggestion
  case blocking
}

public enum TatwoArtifactReviewAnnotationStateV1:
  String,
  Codable,
  Sendable,
  CaseIterable,
  Equatable
{
  case open
  case resolved
}

public struct TatwoArtifactReviewAnnotationV1:
  Codable,
  Sendable,
  Identifiable,
  Equatable
{
  public let id: String
  public let targetKind: TatwoArtifactReviewAnnotationTargetKindV1
  public let targetID: String
  public let authorIdentity: String
  public let body: String
  public let severity: TatwoArtifactReviewAnnotationSeverityV1
  public let state: TatwoArtifactReviewAnnotationStateV1
  public let createdAt: Date

  public init(
    id: String,
    targetKind: TatwoArtifactReviewAnnotationTargetKindV1,
    targetID: String,
    authorIdentity: String,
    body: String,
    severity: TatwoArtifactReviewAnnotationSeverityV1,
    state: TatwoArtifactReviewAnnotationStateV1,
    createdAt: Date
  ) {
    self.id = id
    self.targetKind = targetKind
    self.targetID = targetID
    self.authorIdentity = authorIdentity
    self.body = body
    self.severity = severity
    self.state = state
    self.createdAt = createdAt
  }
}

public struct TatwoArtifactReviewAnnotationGroupV1: Codable, Sendable, Equatable {
  public let targetKind: TatwoArtifactReviewAnnotationTargetKindV1
  public let targetID: String
  public let annotations: [TatwoArtifactReviewAnnotationV1]
  public let openCount: Int
  public let resolvedCount: Int
  public let openBlockingCount: Int

  public init(
    targetKind: TatwoArtifactReviewAnnotationTargetKindV1,
    targetID: String,
    annotations: [TatwoArtifactReviewAnnotationV1],
    openCount: Int,
    resolvedCount: Int,
    openBlockingCount: Int
  ) {
    self.targetKind = targetKind
    self.targetID = targetID
    self.annotations = annotations
    self.openCount = max(0, openCount)
    self.resolvedCount = max(0, resolvedCount)
    self.openBlockingCount = max(0, openBlockingCount)
  }
}

public struct TatwoArtifactReviewAnnotationAggregateV1: Codable, Sendable, Equatable {
  public let schema: String
  public let groups: [TatwoArtifactReviewAnnotationGroupV1]
  public let totalCount: Int
  public let openCount: Int
  public let resolvedCount: Int
  public let openBlockingCount: Int
  public let orphanedDiffAnnotationIDs: [String]

  public init(
    schema: String = "TatwoArtifactReviewAnnotationAggregateV1",
    groups: [TatwoArtifactReviewAnnotationGroupV1],
    totalCount: Int,
    openCount: Int,
    resolvedCount: Int,
    openBlockingCount: Int,
    orphanedDiffAnnotationIDs: [String]
  ) {
    self.schema = schema
    self.groups = groups
    self.totalCount = max(0, totalCount)
    self.openCount = max(0, openCount)
    self.resolvedCount = max(0, resolvedCount)
    self.openBlockingCount = max(0, openBlockingCount)
    self.orphanedDiffAnnotationIDs = orphanedDiffAnnotationIDs
  }
}

public enum TatwoArtifactReviewAnnotationAggregator {
  public static func aggregate(
    annotations: [TatwoArtifactReviewAnnotationV1],
    diff: TatwoArtifactReviewModificationDiffV1? = nil
  ) -> TatwoArtifactReviewAnnotationAggregateV1 {
    struct GroupKey: Hashable {
      let kind: TatwoArtifactReviewAnnotationTargetKindV1
      let id: String
    }

    let sortedAnnotations = annotations.sorted {
      if $0.createdAt != $1.createdAt {
        return $0.createdAt < $1.createdAt
      }
      return $0.id < $1.id
    }
    let grouped = Dictionary(
      grouping: sortedAnnotations,
      by: { GroupKey(kind: $0.targetKind, id: $0.targetID) })
    let groups = grouped.map { key, values in
      TatwoArtifactReviewAnnotationGroupV1(
        targetKind: key.kind,
        targetID: key.id,
        annotations: values,
        openCount: values.filter { $0.state == .open }.count,
        resolvedCount: values.filter { $0.state == .resolved }.count,
        openBlockingCount: values.filter {
          $0.state == .open && $0.severity == .blocking
        }.count)
    }
    .sorted {
      if $0.targetKind.rawValue != $1.targetKind.rawValue {
        return $0.targetKind.rawValue < $1.targetKind.rawValue
      }
      return $0.targetID < $1.targetID
    }

    let knownHunkIDs = diff.map { Set($0.hunks.map(\.id)) }
    let orphaned = sortedAnnotations.compactMap { annotation -> String? in
      guard annotation.targetKind == .diffHunk,
            let knownHunkIDs,
            !knownHunkIDs.contains(annotation.targetID)
      else {
        return nil
      }
      return annotation.id
    }

    return TatwoArtifactReviewAnnotationAggregateV1(
      groups: groups,
      totalCount: sortedAnnotations.count,
      openCount: sortedAnnotations.filter { $0.state == .open }.count,
      resolvedCount: sortedAnnotations.filter { $0.state == .resolved }.count,
      openBlockingCount: sortedAnnotations.filter {
        $0.state == .open && $0.severity == .blocking
      }.count,
      orphanedDiffAnnotationIDs: orphaned)
  }
}
