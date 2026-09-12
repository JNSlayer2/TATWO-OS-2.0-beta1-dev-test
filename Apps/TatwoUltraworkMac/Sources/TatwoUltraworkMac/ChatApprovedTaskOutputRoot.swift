import Foundation

/// The Chat runner may receive one additional writable root only for a
/// confirmed Goal/PLG execution turn. The prompt is never treated as a
/// general filesystem capability: only a unique descendant of the fixed
/// TatwoSandbox test root can opt in.
enum ChatApprovedTaskOutputRoot {
    static let allowlistRoot = URL(
        fileURLWithPath: "\(NSHomeDirectory())/Library/Application Support/tatwo2/runtime/sandbox/test",
        isDirectory: true
    ).standardizedFileURL

    enum Resolution: Equatable {
        case none
        case approved(targetPath: String)
        case invalid
        case ambiguous([String])
    }

    static func resolve(in text: String) -> Resolution {
        resolve(
            in: text,
            allowlistRoot: allowlistRoot,
            fileManager: .default)
    }

    /// Resolves both the trusted root and an extracted candidate through the
    /// filesystem before granting that one canonical target as writable. The
    /// injectable root exists
    /// for deterministic security regression tests; production always calls
    /// `resolve(in:)` with `allowlistRoot`.
    static func resolve(
        in text: String,
        allowlistRoot: URL,
        fileManager: FileManager
    ) -> Resolution {
        let lexicalRoot = allowlistRoot.standardizedFileURL
        let lexicalRootPath = lexicalRoot.path
        guard text.contains(lexicalRootPath) else { return .none }

        guard let resolvedRoot = resolvedExistingDirectory(
            lexicalRoot,
            fileManager: fileManager)
        else {
            return .invalid
        }
        let resolvedRootPath = resolvedRoot.path

        var results: [String] = []
        var searchStart = text.startIndex
        while let range = text.range(
            of: lexicalRootPath,
            range: searchStart..<text.endIndex)
        {
            let suffix = text[range.lowerBound...]
            let raw = String(suffix.prefix { character in
                character != "\n"
                    && character != "\r"
                    && character != "`"
                    && character != "\""
                    && character != "'"
            })
            let trimmed = raw.trimmingCharacters(
                in: CharacterSet.whitespacesAndNewlines.union(
                    CharacterSet(charactersIn: "，。；;、）)]}＞>")))
            let standardized = URL(
                fileURLWithPath: trimmed,
                isDirectory: true
            ).standardizedFileURL

            // Reject lexical traversal before consulting the filesystem. This
            // also prevents a prompt from using the allowlist path merely as a
            // prefix for a different sibling directory.
            guard isDescendantOrSame(
                standardized.path,
                of: lexicalRootPath)
            else {
                searchStart = range.upperBound
                continue
            }

            // Descendant symlinks are deliberately fail-closed, even when
            // their current destination remains inside the root. Returning a
            // canonical path is not enough to make a later path-based write
            // race-free if an untrusted descendant alias can be swapped.
            guard containsSymlink(
                below: lexicalRoot,
                through: standardized,
                fileManager: fileManager) == false
            else {
                searchStart = range.upperBound
                continue
            }

            // `resolvingSymlinksInPath()` only resolves existing components.
            // Resolve the nearest existing ancestor, then append the missing
            // suffix so a child below an escaping symlink cannot be approved.
            guard let resolvedCandidate = TatwoCanonicalPath.resolvedURL(
                preservingMissingSuffixOf: standardized,
                fileManager: fileManager)
            else {
                searchStart = range.upperBound
                continue
            }
            let resolvedCandidatePath = resolvedCandidate.path

            if isDescendantOrSame(
                resolvedCandidatePath,
                of: resolvedRootPath),
               !results.contains(resolvedCandidatePath)
            {
                results.append(resolvedCandidatePath)
            }
            searchStart = range.upperBound
        }

        switch results.count {
        case 0:
            return .invalid
        case 1:
            return .approved(targetPath: results[0])
        default:
            return .ambiguous(results.sorted())
        }
    }

    /// Revalidates the exact approved target immediately before it crosses the
    /// process-launch boundary. Approval is deliberately path-scoped rather
    /// than root-scoped, and a target or ancestor replaced by a symlink after
    /// prompt resolution fails closed.
    static func revalidatedWritableTarget(
        _ targetPath: String,
        allowlistRoot: URL = allowlistRoot,
        fileManager: FileManager = .default
    ) -> String? {
        guard let resolvedRoot = resolvedExistingDirectory(
            allowlistRoot.standardizedFileURL,
            fileManager: fileManager)
        else {
            return nil
        }
        let target = URL(
            fileURLWithPath: targetPath,
            isDirectory: true
        ).standardizedFileURL
        guard isDescendantOrSame(target.path, of: resolvedRoot.path),
              containsSymlink(
                below: resolvedRoot,
                through: target,
                fileManager: fileManager) == false,
              let revalidated = TatwoCanonicalPath.resolvedURL(
                preservingMissingSuffixOf: target,
                fileManager: fileManager),
              revalidated.path == target.path,
              isDescendantOrSame(revalidated.path, of: resolvedRoot.path)
        else {
            return nil
        }
        return revalidated.path
    }

    private static func resolvedExistingDirectory(
        _ url: URL,
        fileManager: FileManager
    ) -> URL? {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: url.path,
            isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            return nil
        }
        return url.resolvingSymlinksInPath().standardizedFileURL
    }

    /// Returns `nil` when filesystem state cannot be inspected safely.
    private static func containsSymlink(
        below root: URL,
        through candidate: URL,
        fileManager: FileManager
    ) -> Bool? {
        let rootComponents = root.standardizedFileURL.pathComponents
        let candidateComponents =
            candidate.standardizedFileURL.pathComponents
        guard candidateComponents.starts(with: rootComponents) else {
            return nil
        }

        var prefix = root.standardizedFileURL
        for component in candidateComponents.dropFirst(rootComponents.count) {
            prefix.appendPathComponent(component, isDirectory: true)
            if (try? fileManager.destinationOfSymbolicLink(
                atPath: prefix.path)) != nil
            {
                return true
            }
            if fileManager.fileExists(atPath: prefix.path) {
                continue
            }
            do {
                _ = try fileManager.attributesOfItem(atPath: prefix.path)
            } catch let error as CocoaError
                where error.code == .fileNoSuchFile
                    || error.code == .fileReadNoSuchFile
            {
                return false
            } catch {
                return nil
            }
        }
        return false
    }

    private static func isDescendantOrSame(
        _ candidate: String,
        of root: String
    ) -> Bool {
        candidate == root || candidate.hasPrefix(root + "/")
    }
}
