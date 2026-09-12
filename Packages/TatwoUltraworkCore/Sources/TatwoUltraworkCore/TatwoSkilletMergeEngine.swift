import CryptoKit
import Foundation

public enum TatwoSkilletMergeConflictKindV1: String, Codable, Hashable, Sendable {
    case addAdd
    case deleteModify
    case overlappingTextEdits
    case binaryChange
    case mergeComplexityExceeded
    case unrelatedHistory
    case renameRename
    case renameCollision
}

public struct TatwoSkilletMergeConflictArtifactV1:
    Codable, Hashable, Sendable, Identifiable
{
    public let id: String
    public let repositoryID: String
    public let sourceDeviceID: String
    public let baseRevisionID: String?
    public let canonicalRevisionID: String
    public let proposedRevisionID: String
    public let relativePath: String
    public let kind: TatwoSkilletMergeConflictKindV1
    public let baseContentDigest: String?
    public let canonicalContentDigest: String?
    public let proposedContentDigest: String?

    public init(
        id: String,
        repositoryID: String,
        sourceDeviceID: String,
        baseRevisionID: String?,
        canonicalRevisionID: String,
        proposedRevisionID: String,
        relativePath: String,
        kind: TatwoSkilletMergeConflictKindV1,
        baseContentDigest: String?,
        canonicalContentDigest: String?,
        proposedContentDigest: String?
    ) {
        self.id = id
        self.repositoryID = repositoryID
        self.sourceDeviceID = sourceDeviceID
        self.baseRevisionID = baseRevisionID
        self.canonicalRevisionID = canonicalRevisionID
        self.proposedRevisionID = proposedRevisionID
        self.relativePath = relativePath
        self.kind = kind
        self.baseContentDigest = baseContentDigest
        self.canonicalContentDigest = canonicalContentDigest
        self.proposedContentDigest = proposedContentDigest
    }
}

public struct TatwoSkilletMergeResultV1: Equatable, Sendable {
    public let mergedFiles: [String: Data]
    public let conflicts: [TatwoSkilletMergeConflictArtifactV1]
    public let changedPaths: [String]

    public init(
        mergedFiles: [String: Data],
        conflicts: [TatwoSkilletMergeConflictArtifactV1],
        changedPaths: [String]
    ) {
        self.mergedFiles = mergedFiles
        self.conflicts = conflicts
        self.changedPaths = changedPaths
    }

    public var isClean: Bool {
        conflicts.isEmpty
    }
}

/// Deterministic three-way merge for immutable Skillet snapshots.
///
/// The engine never writes conflict markers into a skill. A conflicting file
/// is omitted from the merged candidate and represented by a deterministic
/// conflict artifact that carries all branch provenance.
public enum TatwoSkilletMergeEngine {
    static let maximumMergeLineCount = 20_000
    static let maximumMergeAggregateBytes = 2_097_152
    static let maximumLCSTableCells = 4_000_000

    public static func merge(
        repositoryID: String,
        sourceDeviceID: String,
        baseRevisionID: String?,
        canonicalRevisionID: String,
        proposedRevisionID: String,
        baseFiles: [String: Data]?,
        canonicalFiles: [String: Data],
        proposedFiles: [String: Data]
    ) -> TatwoSkilletMergeResultV1 {
        guard let baseFiles else {
            let conflict = makeConflict(
                repositoryID: repositoryID,
                sourceDeviceID: sourceDeviceID,
                baseRevisionID: nil,
                canonicalRevisionID: canonicalRevisionID,
                proposedRevisionID: proposedRevisionID,
                relativePath: "__repository__",
                kind: .unrelatedHistory,
                base: nil,
                canonical: nil,
                proposed: nil
            )
            return TatwoSkilletMergeResultV1(
                mergedFiles: [:],
                conflicts: [conflict],
                changedPaths: []
            )
        }

        var base = baseFiles
        var canonical = canonicalFiles
        var proposed = proposedFiles
        let renameNormalization = normalizeRenames(
            repositoryID: repositoryID,
            sourceDeviceID: sourceDeviceID,
            baseRevisionID: baseRevisionID,
            canonicalRevisionID: canonicalRevisionID,
            proposedRevisionID: proposedRevisionID,
            base: &base,
            canonical: &canonical,
            proposed: &proposed
        )

        var merged: [String: Data] = [:]
        var conflicts = renameNormalization.conflicts
        let blockedPaths = renameNormalization.blockedPaths
        let allPaths = Set(base.keys)
            .union(canonical.keys)
            .union(proposed.keys)
            .subtracting(blockedPaths)
            .sorted()

        for path in allPaths {
            let base = base[path]
            let current = canonical[path]
            let incoming = proposed[path]

            if current == incoming {
                if let current {
                    merged[path] = current
                }
                continue
            }
            if current == base {
                if let incoming {
                    merged[path] = incoming
                }
                continue
            }
            if incoming == base {
                if let current {
                    merged[path] = current
                }
                continue
            }

            switch (base, current, incoming) {
            case (nil, let current?, let incoming?):
                conflicts.append(
                    makeConflict(
                        repositoryID: repositoryID,
                        sourceDeviceID: sourceDeviceID,
                        baseRevisionID: baseRevisionID,
                        canonicalRevisionID: canonicalRevisionID,
                        proposedRevisionID: proposedRevisionID,
                        relativePath: path,
                        kind: .addAdd,
                        base: nil,
                        canonical: current,
                        proposed: incoming
                    )
                )
            case (let base?, nil, _),
                 (let base?, _, nil):
                conflicts.append(
                    makeConflict(
                        repositoryID: repositoryID,
                        sourceDeviceID: sourceDeviceID,
                        baseRevisionID: baseRevisionID,
                        canonicalRevisionID: canonicalRevisionID,
                        proposedRevisionID: proposedRevisionID,
                        relativePath: path,
                        kind: .deleteModify,
                        base: base,
                        canonical: current,
                        proposed: incoming
                    )
                )
            case (let base?, let current?, let incoming?):
                guard isMergeableText(base),
                      isMergeableText(current),
                      isMergeableText(incoming),
                      let baseText = String(data: base, encoding: .utf8),
                      let currentText = String(data: current, encoding: .utf8),
                      let incomingText = String(data: incoming, encoding: .utf8)
                else {
                    conflicts.append(
                        makeConflict(
                            repositoryID: repositoryID,
                            sourceDeviceID: sourceDeviceID,
                            baseRevisionID: baseRevisionID,
                            canonicalRevisionID: canonicalRevisionID,
                            proposedRevisionID: proposedRevisionID,
                            relativePath: path,
                            kind: .binaryChange,
                            base: base,
                            canonical: current,
                            proposed: incoming
                        )
                    )
                    continue
                }
                guard isMergeComplexitySafe(
                    base: baseText,
                    canonical: currentText,
                    proposed: incomingText
                ) else {
                    conflicts.append(
                        makeConflict(
                            repositoryID: repositoryID,
                            sourceDeviceID: sourceDeviceID,
                            baseRevisionID: baseRevisionID,
                            canonicalRevisionID: canonicalRevisionID,
                            proposedRevisionID: proposedRevisionID,
                            relativePath: path,
                            kind: .mergeComplexityExceeded,
                            base: base,
                            canonical: current,
                            proposed: incoming
                        )
                    )
                    continue
                }
                if let text = mergeText(
                    base: baseText,
                    canonical: currentText,
                    proposed: incomingText
                ) {
                    merged[path] = Data(text.utf8)
                } else {
                    conflicts.append(
                        makeConflict(
                            repositoryID: repositoryID,
                            sourceDeviceID: sourceDeviceID,
                            baseRevisionID: baseRevisionID,
                            canonicalRevisionID: canonicalRevisionID,
                            proposedRevisionID: proposedRevisionID,
                            relativePath: path,
                            kind: .overlappingTextEdits,
                            base: base,
                            canonical: current,
                            proposed: incoming
                        )
                    )
                }
            case (nil, nil, _), (nil, _, nil), (_, nil, nil):
                // Handled by equality/base-equality rules above.
                break
            }
        }

        var prefixBlockedPaths = Set<String>()
        for (parent, child) in pathPrefixCollisions(in: merged.keys) {
            prefixBlockedPaths.formUnion([parent, child])
        }
        var existingConflictIDs = Set(conflicts.map(\.id))
        for path in prefixBlockedPaths.sorted() {
            let conflict = makeConflict(
                repositoryID: repositoryID,
                sourceDeviceID: sourceDeviceID,
                baseRevisionID: baseRevisionID,
                canonicalRevisionID: canonicalRevisionID,
                proposedRevisionID: proposedRevisionID,
                relativePath: path,
                kind: .renameCollision,
                base: base[path],
                canonical: canonical[path],
                proposed: proposed[path]
            )
            if existingConflictIDs.insert(conflict.id).inserted {
                conflicts.append(conflict)
            }
            merged.removeValue(forKey: path)
        }

        conflicts.sort {
            if $0.relativePath == $1.relativePath {
                return $0.id < $1.id
            }
            return $0.relativePath < $1.relativePath
        }
        let changedPaths = Set(baseFiles.keys)
            .union(merged.keys)
            .filter { baseFiles[$0] != merged[$0] }
            .sorted()
        return TatwoSkilletMergeResultV1(
            mergedFiles: merged,
            conflicts: conflicts,
            changedPaths: changedPaths
        )
    }
}

private extension TatwoSkilletMergeEngine {
    struct TextEdit: Equatable {
        let range: Range<Int>
        let replacement: [String]
    }

    struct RenameNormalization {
        let conflicts: [TatwoSkilletMergeConflictArtifactV1]
        let blockedPaths: Set<String>
    }

    static func normalizeRenames(
        repositoryID: String,
        sourceDeviceID: String,
        baseRevisionID: String?,
        canonicalRevisionID: String,
        proposedRevisionID: String,
        base: inout [String: Data],
        canonical: inout [String: Data],
        proposed: inout [String: Data]
    ) -> RenameNormalization {
        let canonicalRenames = exactRenames(base: base, side: canonical)
        let proposedRenames = exactRenames(base: base, side: proposed)
        var conflicts: [TatwoSkilletMergeConflictArtifactV1] = []
        var blocked = Set<String>()

        for oldPath in Set(canonicalRenames.keys)
            .union(proposedRenames.keys)
            .sorted()
        {
            let canonicalDestination = canonicalRenames[oldPath]
            let proposedDestination = proposedRenames[oldPath]

            if let canonicalDestination,
               let proposedDestination,
               canonicalDestination != proposedDestination
            {
                conflicts.append(
                    makeConflict(
                        repositoryID: repositoryID,
                        sourceDeviceID: sourceDeviceID,
                        baseRevisionID: baseRevisionID,
                        canonicalRevisionID: canonicalRevisionID,
                        proposedRevisionID: proposedRevisionID,
                        relativePath: oldPath,
                        kind: .renameRename,
                        base: base[oldPath],
                        canonical: canonical[canonicalDestination],
                        proposed: proposed[proposedDestination]
                    )
                )
                blocked.formUnion([
                    oldPath,
                    canonicalDestination,
                    proposedDestination,
                ])
                continue
            }

            let destination = canonicalDestination ?? proposedDestination
            guard let destination else { continue }

            if canonicalDestination != nil, proposedDestination == nil {
                guard proposed[destination] == nil else {
                    conflicts.append(
                        makeConflict(
                            repositoryID: repositoryID,
                            sourceDeviceID: sourceDeviceID,
                            baseRevisionID: baseRevisionID,
                            canonicalRevisionID: canonicalRevisionID,
                            proposedRevisionID: proposedRevisionID,
                            relativePath: destination,
                            kind: .renameCollision,
                            base: base[oldPath],
                            canonical: canonical[destination],
                            proposed: proposed[destination]
                        )
                    )
                    blocked.formUnion([oldPath, destination])
                    continue
                }
                if let other = proposed.removeValue(forKey: oldPath) {
                    proposed[destination] = other
                }
            } else if proposedDestination != nil, canonicalDestination == nil {
                guard canonical[destination] == nil else {
                    conflicts.append(
                        makeConflict(
                            repositoryID: repositoryID,
                            sourceDeviceID: sourceDeviceID,
                            baseRevisionID: baseRevisionID,
                            canonicalRevisionID: canonicalRevisionID,
                            proposedRevisionID: proposedRevisionID,
                            relativePath: destination,
                            kind: .renameCollision,
                            base: base[oldPath],
                            canonical: canonical[destination],
                            proposed: proposed[destination]
                        )
                    )
                    blocked.formUnion([oldPath, destination])
                    continue
                }
                if let other = canonical.removeValue(forKey: oldPath) {
                    canonical[destination] = other
                }
            }
            if let ancestor = base.removeValue(forKey: oldPath) {
                base[destination] = ancestor
            }
        }
        return RenameNormalization(conflicts: conflicts, blockedPaths: blocked)
    }

    static func exactRenames(
        base: [String: Data],
        side: [String: Data]
    ) -> [String: String] {
        let added = side.keys.filter { base[$0] == nil }.sorted()
        var additionsByDigest: [String: [String]] = [:]
        for path in added {
            guard let data = side[path] else { continue }
            additionsByDigest[digest(data), default: []].append(path)
        }

        var result: [String: String] = [:]
        for oldPath in base.keys.filter({ side[$0] == nil }).sorted() {
            guard let data = base[oldPath],
                  let destinations = additionsByDigest[digest(data)],
                  destinations.count == 1
            else {
                continue
            }
            result[oldPath] = destinations[0]
        }
        return result
    }

    static func mergeText(
        base: String,
        canonical: String,
        proposed: String
    ) -> String? {
        guard isMergeComplexitySafe(
            base: base,
            canonical: canonical,
            proposed: proposed
        ) else {
            return nil
        }
        let baseLines = base.components(separatedBy: "\n")
        let canonicalEdits = edits(
            from: baseLines,
            to: canonical.components(separatedBy: "\n")
        )
        let proposedEdits = edits(
            from: baseLines,
            to: proposed.components(separatedBy: "\n")
        )

        var combined = canonicalEdits
        for proposedEdit in proposedEdits {
            if combined.contains(proposedEdit) {
                continue
            }
            if combined.contains(where: { editsConflict($0, proposedEdit) }) {
                return nil
            }
            combined.append(proposedEdit)
        }

        var output = baseLines
        combined.sort {
            if $0.range.lowerBound == $1.range.lowerBound {
                if $0.range.upperBound == $1.range.upperBound {
                    return $0.replacement.lexicographicallyPrecedes($1.replacement)
                }
                return $0.range.upperBound > $1.range.upperBound
            }
            return $0.range.lowerBound > $1.range.lowerBound
        }
        for edit in combined {
            output.replaceSubrange(edit.range, with: edit.replacement)
        }
        return output.joined(separator: "\n")
    }

    static func edits(
        from base: [String],
        to variant: [String]
    ) -> [TextEdit] {
        let rows = base.count + 1
        let columns = variant.count + 1
        var lcs = Array(repeating: 0, count: rows * columns)
        func index(_ row: Int, _ column: Int) -> Int {
            row * columns + column
        }
        if !base.isEmpty, !variant.isEmpty {
            for row in stride(from: base.count - 1, through: 0, by: -1) {
                for column in stride(from: variant.count - 1, through: 0, by: -1) {
                    if base[row] == variant[column] {
                        lcs[index(row, column)] = 1 + lcs[index(row + 1, column + 1)]
                    } else {
                        lcs[index(row, column)] = max(
                            lcs[index(row + 1, column)],
                            lcs[index(row, column + 1)]
                        )
                    }
                }
            }
        }

        enum Operation {
            case equal
            case delete
            case insert(String)
        }
        var operations: [Operation] = []
        var row = 0
        var column = 0
        while row < base.count || column < variant.count {
            if row < base.count,
               column < variant.count,
               base[row] == variant[column]
            {
                operations.append(.equal)
                row += 1
                column += 1
            } else if row < base.count,
                      (column == variant.count
                        || lcs[index(row + 1, column)]
                            >= lcs[index(row, column + 1)])
            {
                operations.append(.delete)
                row += 1
            } else {
                operations.append(.insert(variant[column]))
                column += 1
            }
        }

        var edits: [TextEdit] = []
        var baseIndex = 0
        var operationIndex = 0
        while operationIndex < operations.count {
            if case .equal = operations[operationIndex] {
                baseIndex += 1
                operationIndex += 1
                continue
            }
            let start = baseIndex
            var replacement: [String] = []
            while operationIndex < operations.count {
                switch operations[operationIndex] {
                case .equal:
                    operationIndex = operations.count
                    continue
                case .delete:
                    baseIndex += 1
                case .insert(let line):
                    replacement.append(line)
                }
                operationIndex += 1
                if operationIndex < operations.count,
                   case .equal = operations[operationIndex]
                {
                    break
                }
            }
            edits.append(
                TextEdit(
                    range: start..<baseIndex,
                    replacement: replacement
                )
            )
        }
        return edits
    }

    static func editsConflict(_ first: TextEdit, _ second: TextEdit) -> Bool {
        if first == second {
            return false
        }
        if first.range.isEmpty, second.range.isEmpty {
            return first.range.lowerBound == second.range.lowerBound
        }
        if first.range.isEmpty {
            let point = first.range.lowerBound
            return point > second.range.lowerBound && point < second.range.upperBound
        }
        if second.range.isEmpty {
            let point = second.range.lowerBound
            return point > first.range.lowerBound && point < first.range.upperBound
        }
        return max(first.range.lowerBound, second.range.lowerBound)
            < min(first.range.upperBound, second.range.upperBound)
    }

    static func isMergeableText(_ data: Data) -> Bool {
        data.count <= 1_048_576
            && !data.contains(0)
            && String(data: data, encoding: .utf8) != nil
    }

    static func isMergeComplexitySafe(
        base: String,
        canonical: String,
        proposed: String
    ) -> Bool {
        let byteCounts = [
            base.utf8.count,
            canonical.utf8.count,
            proposed.utf8.count,
        ]
        guard byteCounts.reduce(0, +) <= maximumMergeAggregateBytes else {
            return false
        }

        let lineCounts = [
            lineCount(base),
            lineCount(canonical),
            lineCount(proposed),
        ]
        guard lineCounts.allSatisfy({ $0 <= maximumMergeLineCount }) else {
            return false
        }

        return lcsCellCountIsSafe(
            rows: lineCounts[0] + 1,
            columns: lineCounts[1] + 1
        ) && lcsCellCountIsSafe(
            rows: lineCounts[0] + 1,
            columns: lineCounts[2] + 1
        )
    }

    static func pathPrefixCollisions<S: Sequence>(
        in paths: S
    ) -> [(String, String)] where S.Element == String {
        let pathSet = Set(paths)
        var collisions: [(String, String)] = []
        for child in pathSet.sorted() {
            let components = child.split(separator: "/")
            guard components.count > 1 else { continue }
            for count in 1..<components.count {
                let parent = components.prefix(count).joined(separator: "/")
                if pathSet.contains(parent) {
                    collisions.append((parent, child))
                }
            }
        }
        return collisions
    }

    private static func lineCount(_ text: String) -> Int {
        1 + text.utf8.reduce(into: 0) { count, byte in
            if byte == 0x0A {
                count += 1
            }
        }
    }

    private static func lcsCellCountIsSafe(
        rows: Int,
        columns: Int
    ) -> Bool {
        let (count, overflow) = rows.multipliedReportingOverflow(by: columns)
        return !overflow && count <= maximumLCSTableCells
    }

    static func makeConflict(
        repositoryID: String,
        sourceDeviceID: String,
        baseRevisionID: String?,
        canonicalRevisionID: String,
        proposedRevisionID: String,
        relativePath: String,
        kind: TatwoSkilletMergeConflictKindV1,
        base: Data?,
        canonical: Data?,
        proposed: Data?
    ) -> TatwoSkilletMergeConflictArtifactV1 {
        let baseDigest = base.map(digest)
        let canonicalDigest = canonical.map(digest)
        let proposedDigest = proposed.map(digest)
        let components = [
            repositoryID,
            sourceDeviceID,
            baseRevisionID ?? "",
            canonicalRevisionID,
            proposedRevisionID,
            relativePath,
            kind.rawValue,
            baseDigest ?? "",
            canonicalDigest ?? "",
            proposedDigest ?? "",
        ]
        var bytes = Data()
        for component in components {
            let data = Data(component.utf8)
            var count = UInt64(data.count).bigEndian
            withUnsafeBytes(of: &count) { bytes.append(contentsOf: $0) }
            bytes.append(data)
        }
        return TatwoSkilletMergeConflictArtifactV1(
            id: "conflict-\(digest(bytes))",
            repositoryID: repositoryID,
            sourceDeviceID: sourceDeviceID,
            baseRevisionID: baseRevisionID,
            canonicalRevisionID: canonicalRevisionID,
            proposedRevisionID: proposedRevisionID,
            relativePath: relativePath,
            kind: kind,
            baseContentDigest: baseDigest,
            canonicalContentDigest: canonicalDigest,
            proposedContentDigest: proposedDigest
        )
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
