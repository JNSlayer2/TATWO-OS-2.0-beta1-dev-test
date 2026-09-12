import Foundation
import TatwoModuleContracts
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum TatwoBundleActivationError: Error, Equatable, Sendable {
    case invalidRole(expected: TatwoBundlePathRoleV1, actual: TatwoBundlePathRoleV1)
    case nonAbsolutePath(String)
    case pathResolutionFailed(candidate: String, errno: Int32)
    case tooManySymbolicLinks(String)
    case activeBundleMismatch(candidate: String, installRoot: String)
    case pathOutsideAllowedRoots(candidate: String, allowedRoots: [String])
    case protectedPathOverlap(candidate: String, protectedRoot: String, kind: TatwoProtectedPathKindV1)
}

public final class TatwoBundleActivationService: TatwoBundleActivationPort, TatwoBootstrapDeploymentPort {
    private let fileSystem: any TatwoBundleFileSystemPort
    private let verifier: any TatwoBundleVerifierPort
    private let healthChecker: any TatwoBundleHealthCheckPort
    private let makeReceiptID: () -> String
    private let now: () -> Date

    public init(
        fileSystem: any TatwoBundleFileSystemPort,
        verifier: any TatwoBundleVerifierPort,
        healthChecker: any TatwoBundleHealthCheckPort,
        receiptID: @escaping () -> String = { UUID().uuidString },
        now: @escaping () -> Date = Date.init
    ) {
        self.fileSystem = fileSystem
        self.verifier = verifier
        self.healthChecker = healthChecker
        self.makeReceiptID = receiptID
        self.now = now
    }

    public func stage(_ request: TatwoBundleStageRequestV1) throws -> TatwoBundleOperationReceiptV1 {
        try validate(request.sourceBundle, expectedRole: .sourceArtifact, boundary: request.boundary)
        try validate(request.stagedBundle, expectedRole: .stagedBundle, boundary: request.boundary)
        try requireContained(request.stagedBundle.path, in: request.boundary.stagingRoots)
        try fileSystem.stageBundle(from: request.sourceBundle, to: request.stagedBundle)
        return .succeeded(
            operation: .stage,
            moduleID: request.boundary.moduleID,
            correlationID: request.correlationID,
            receiptID: makeReceiptID(),
            createdAt: now(),
            bundlePaths: [request.sourceBundle, request.stagedBundle],
            detail: "Bundle staged"
        )
    }

    public func verify(_ request: TatwoBundleVerifyRequestV1) throws -> TatwoBundleOperationReceiptV1 {
        try validate(request.stagedBundle, expectedRole: .stagedBundle, boundary: request.boundary)
        try requireContained(request.stagedBundle.path, in: request.boundary.stagingRoots)
        let result = try verifier.verifyBundle(request)
        let valid = result.isValid && result.observedDigest == request.expectedArtifactDigest
        let detail = valid
            ? result.detail
            : "\(result.detail); expectedDigest=\(request.expectedArtifactDigest); observedDigest=\(result.observedDigest)"
        return receipt(
            operation: .verify,
            moduleID: request.boundary.moduleID,
            correlationID: request.correlationID,
            paths: [request.stagedBundle],
            succeeded: valid,
            detail: detail
        )
    }

    public func archiveCurrent(
        _ request: TatwoBundleArchiveCurrentRequestV1
    ) throws -> TatwoBundleOperationReceiptV1 {
        try validateActive(request.currentBundle, boundary: request.boundary)
        try validate(request.archivedBundle, expectedRole: .archivedBundle, boundary: request.boundary)
        try requireContained(request.archivedBundle.path, in: request.boundary.archiveRoots)
        try fileSystem.archiveBundle(from: request.currentBundle, to: request.archivedBundle)
        return .succeeded(
            operation: .archiveCurrent,
            moduleID: request.boundary.moduleID,
            correlationID: request.correlationID,
            receiptID: makeReceiptID(),
            createdAt: now(),
            bundlePaths: [request.currentBundle, request.archivedBundle],
            detail: "Current bundle archived"
        )
    }

    public func atomicSwap(
        _ request: TatwoBundleAtomicSwapRequestV1
    ) throws -> TatwoBundleOperationReceiptV1 {
        try validate(request.stagedBundle, expectedRole: .stagedBundle, boundary: request.boundary)
        try requireContained(request.stagedBundle.path, in: request.boundary.stagingRoots)
        try validateActive(request.activeBundle, boundary: request.boundary)
        try fileSystem.atomicSwap(staged: request.stagedBundle, active: request.activeBundle)
        return .succeeded(
            operation: .atomicSwap,
            moduleID: request.boundary.moduleID,
            correlationID: request.correlationID,
            receiptID: makeReceiptID(),
            createdAt: now(),
            bundlePaths: [request.stagedBundle, request.activeBundle],
            detail: "Bundle atomically activated"
        )
    }

    public func healthCheck(
        _ request: TatwoBundleHealthCheckRequestV1
    ) throws -> TatwoBundleOperationReceiptV1 {
        try validateActive(request.activeBundle, boundary: request.boundary)
        let result = try healthChecker.healthCheckBundle(request)
        return receipt(
            operation: .healthCheck,
            moduleID: request.boundary.moduleID,
            correlationID: request.correlationID,
            paths: [request.activeBundle],
            succeeded: result.isHealthy,
            detail: result.detail
        )
    }

    public func rollbackBundle(
        _ request: TatwoBundleRollbackRequestV1
    ) throws -> TatwoBundleOperationReceiptV1 {
        try validate(request.archivedBundle, expectedRole: .rollbackBundle, boundary: request.boundary)
        try requireContained(request.archivedBundle.path, in: request.boundary.archiveRoots)
        try validateActive(request.activeBundle, boundary: request.boundary)
        try fileSystem.rollbackBundle(from: request.archivedBundle, to: request.activeBundle)
        return .succeeded(
            operation: .rollbackBundle,
            moduleID: request.boundary.moduleID,
            correlationID: request.correlationID,
            receiptID: makeReceiptID(),
            createdAt: now(),
            bundlePaths: [request.archivedBundle, request.activeBundle],
            detail: "Previous verified bundle restored; user data and domain ledger untouched"
        )
    }

    private func validateActive(
        _ path: TatwoBundlePathV1,
        boundary: TatwoBundleActivationBoundaryV1
    ) throws {
        try validate(path, expectedRole: .activeBundle, boundary: boundary)
        let candidate = try canonicalProspectivePath(path.path)
        let installRoot = try canonicalProspectivePath(boundary.installRoot)
        guard candidate == installRoot else {
            throw TatwoBundleActivationError.activeBundleMismatch(
                candidate: path.path,
                installRoot: boundary.installRoot
            )
        }
    }

    private func validate(
        _ path: TatwoBundlePathV1,
        expectedRole: TatwoBundlePathRoleV1,
        boundary: TatwoBundleActivationBoundaryV1
    ) throws {
        guard path.role == expectedRole else {
            throw TatwoBundleActivationError.invalidRole(expected: expectedRole, actual: path.role)
        }

        for root in boundary.protectedUserDataRoots {
            if try contains(path.path, root: root) {
                throw TatwoBundleActivationError.protectedPathOverlap(
                    candidate: path.path,
                    protectedRoot: root,
                    kind: .userData
                )
            }
        }
        for root in boundary.protectedDomainLedgerRoots {
            if try contains(path.path, root: root) {
                throw TatwoBundleActivationError.protectedPathOverlap(
                    candidate: path.path,
                    protectedRoot: root,
                    kind: .domainLedger
                )
            }
        }
    }

    private func requireContained(_ path: String, in roots: [String]) throws {
        for root in roots where try contains(path, root: root) {
            return
        }
        throw TatwoBundleActivationError.pathOutsideAllowedRoots(
            candidate: path,
            allowedRoots: roots
        )
    }

    private func contains(_ path: String, root: String) throws -> Bool {
        let candidate = try canonicalProspectivePath(path)
        let normalizedRoot = try canonicalProspectivePath(root)
        return candidate == normalizedRoot || candidate.hasPrefix(normalizedRoot + "/")
    }

    /// Resolves every existing symlink component, then appends any not-yet-created suffix.
    ///
    /// `URL.standardizedFileURL` alone does not resolve a symlink when the final destination
    /// does not exist yet. Deployment destinations are prospective by definition, so checking
    /// only their lexical path would allow an allowed staging directory to contain a symlink
    /// that escapes into a protected or otherwise unapproved root.
    private func canonicalProspectivePath(_ rawPath: String) throws -> String {
        var pending = pathComponents(of: try lexicallyNormalizedAbsolute(rawPath))
        var resolvedComponents: [String] = []
        var followedSymbolicLinks = 0

        while !pending.isEmpty {
            let component = pending.removeFirst()
            let candidate = path(from: resolvedComponents + [component])
            var metadata = stat()

            if lstat(candidate, &metadata) == 0 {
                if (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFLNK) {
                    followedSymbolicLinks += 1
                    guard followedSymbolicLinks <= 64 else {
                        throw TatwoBundleActivationError.tooManySymbolicLinks(rawPath)
                    }

                    let destination = try symbolicLinkDestination(at: candidate)
                    let destinationPath: String
                    if destination.hasPrefix("/") {
                        destinationPath = destination
                    } else {
                        destinationPath = path(from: resolvedComponents) + "/" + destination
                    }

                    let combined = destinationPath
                        + (pending.isEmpty ? "" : "/" + pending.joined(separator: "/"))
                    pending = pathComponents(of: try lexicallyNormalizedAbsolute(combined))
                    resolvedComponents.removeAll(keepingCapacity: true)
                    continue
                }

                resolvedComponents.append(component)
                continue
            }

            let observedErrno = errno
            if observedErrno == ENOENT {
                return path(from: resolvedComponents + [component] + pending)
            }

            throw TatwoBundleActivationError.pathResolutionFailed(
                candidate: candidate,
                errno: observedErrno
            )
        }

        return path(from: resolvedComponents)
    }

    private func symbolicLinkDestination(at path: String) throws -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let count = path.withCString { pointer in
            buffer.withUnsafeMutableBufferPointer { storage in
                readlink(pointer, storage.baseAddress, Int(PATH_MAX))
            }
        }
        guard count >= 0 else {
            throw TatwoBundleActivationError.pathResolutionFailed(
                candidate: path,
                errno: errno
            )
        }
        guard count < PATH_MAX else {
            throw TatwoBundleActivationError.tooManySymbolicLinks(path)
        }
        return String(decoding: buffer.prefix(Int(count)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private func pathComponents(of path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    private func path(from components: [String]) -> String {
        components.isEmpty ? "/" : "/" + components.joined(separator: "/")
    }

    private func lexicallyNormalizedAbsolute(_ rawPath: String) throws -> String {
        guard rawPath.hasPrefix("/") else {
            throw TatwoBundleActivationError.nonAbsolutePath(rawPath)
        }

        var components: [String] = []
        for component in rawPath.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".":
                continue
            case "..":
                if !components.isEmpty {
                    components.removeLast()
                }
            default:
                components.append(String(component))
            }
        }
        return path(from: components)
    }

    private func receipt(
        operation: TatwoBundleOperationKindV1,
        moduleID: TatwoModuleIDV1,
        correlationID: String,
        paths: [TatwoBundlePathV1],
        succeeded: Bool,
        detail: String
    ) -> TatwoBundleOperationReceiptV1 {
        TatwoBundleOperationReceiptV1(
            receiptID: makeReceiptID(),
            operation: operation,
            moduleID: moduleID,
            correlationID: correlationID,
            createdAt: now(),
            outcome: succeeded ? .succeeded : .failed,
            isolationEvidence: TatwoBundleOnlyMutationEvidenceV1(bundlePaths: paths),
            detail: detail
        )
    }
}

public enum TatwoFoundationBundleFileSystemError: Error, Equatable, Sendable {
    case sourceMissing(String)
    case destinationAlreadyExists(String)
}

public final class TatwoFoundationBundleFileSystem: TatwoBundleFileSystemPort {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func stageBundle(from source: TatwoBundlePathV1, to staged: TatwoBundlePathV1) throws {
        try copyBundle(from: source.path, to: staged.path)
    }

    public func archiveBundle(from current: TatwoBundlePathV1, to archive: TatwoBundlePathV1) throws {
        try copyBundle(from: current.path, to: archive.path)
    }

    public func atomicSwap(staged: TatwoBundlePathV1, active: TatwoBundlePathV1) throws {
        try replaceBundle(at: active.path, with: staged.path)
    }

    public func rollbackBundle(from archive: TatwoBundlePathV1, to active: TatwoBundlePathV1) throws {
        try replaceBundle(at: active.path, with: archive.path)
    }

    private func copyBundle(from source: String, to destination: String) throws {
        guard fileManager.fileExists(atPath: source) else {
            throw TatwoFoundationBundleFileSystemError.sourceMissing(source)
        }
        guard !fileManager.fileExists(atPath: destination) else {
            throw TatwoFoundationBundleFileSystemError.destinationAlreadyExists(destination)
        }
        try fileManager.createDirectory(
            at: URL(fileURLWithPath: destination).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.copyItem(atPath: source, toPath: destination)
    }

    private func replaceBundle(at active: String, with replacement: String) throws {
        guard fileManager.fileExists(atPath: replacement) else {
            throw TatwoFoundationBundleFileSystemError.sourceMissing(replacement)
        }
        try fileManager.createDirectory(
            at: URL(fileURLWithPath: active).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: active) {
            _ = try fileManager.replaceItemAt(
                URL(fileURLWithPath: active),
                withItemAt: URL(fileURLWithPath: replacement),
                backupItemName: nil,
                options: []
            )
        } else {
            try fileManager.moveItem(atPath: replacement, toPath: active)
        }
    }
}
