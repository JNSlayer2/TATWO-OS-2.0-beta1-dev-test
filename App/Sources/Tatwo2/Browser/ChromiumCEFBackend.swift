// 照搬自 Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/ChromiumCEFBackend.swift；最小修剪：移除 TatwoUltraworkCore import，Tatwo2 水電由 Facade 同名 stub 補齊
import AppKit
import Darwin
import SwiftUI
import TatwoCEFBridge

/// Shared filesystem-authority primitive used by Chat output approval and CEF
/// staging roots. It lives beside the profile store rather than under either
/// feature-specific policy.
enum TatwoCanonicalPath {
    /// Resolves the deepest existing ancestor while preserving path components
    /// that have not been created yet. A dangling symbolic-link entry fails
    /// closed instead of being treated as an ordinary missing component.
    static func resolvedURL(
        preservingMissingSuffixOf url: URL,
        fileManager: FileManager = .default
    ) -> URL? {
        var existingAncestor = url.standardizedFileURL
        var missingComponents: [String] = []

        while !fileManager.fileExists(atPath: existingAncestor.path) {
            if (try? fileManager.destinationOfSymbolicLink(
                atPath: existingAncestor.path)) != nil
            {
                return nil
            }
            let component = existingAncestor.lastPathComponent
            guard !component.isEmpty,
                  existingAncestor.path != "/"
            else {
                return nil
            }
            missingComponents.append(component)
            existingAncestor.deleteLastPathComponent()
        }

        var resolved =
            existingAncestor.resolvingSymlinksInPath().standardizedFileURL
        for component in missingComponents.reversed() {
            resolved.appendPathComponent(component, isDirectory: true)
        }
        return resolved.standardizedFileURL
    }
}

enum EmbeddedBrowserEngine: String, Equatable, Sendable {
    case chromiumCEF = "chromium-cef"
    case webKitLegacy = "webkit-legacy"
    case chromiumUnavailable = "chromium-unavailable"
}

enum EmbeddedBrowserEnginePolicy {
    static let stagingBundlePrefix = "com.tatwo.ultrawork.staging."
    static let productionBundleIdentifier = "com.tatwo.ultrawork"
    static let tatwo2ProductionBundleIdentifier = "ai.tatwo.tatwo2"
    static let tatwo2StagingBundleIdentifier = "com.tatwo.ultrawork.staging.tatwo2"
    static let configuredEngineKey = "TatwoBrowserEngine"
    static let stagingRootKey = "TatwoStagingRoot"

    static func selectedEngine(
        bundleIdentifier: String?,
        configuredEngine: String?,
        cefCompiled: Bool = TatwoCEFRuntime.compiled
    ) -> EmbeddedBrowserEngine {
        let isExportMode = ProcessInfo.processInfo.environment.keys.contains {
            $0.hasPrefix("TATWO_ULTRAWORK_EXPORT_")
        }
        guard !isExportMode else { return .chromiumUnavailable }
        let isAuthorizedBundle =
            productionSupportDirectory(for: bundleIdentifier) != nil
            || bundleIdentifier == tatwo2StagingBundleIdentifier
            || bundleIdentifier?.hasPrefix(stagingBundlePrefix) == true
        guard isAuthorizedBundle,
              configuredEngine == EmbeddedBrowserEngine.chromiumCEF.rawValue
        else {
            return .webKitLegacy
        }
        return cefCompiled ? .chromiumCEF : .chromiumUnavailable
    }

    static var current: EmbeddedBrowserEngine {
        selectedEngine(
            bundleIdentifier: Bundle.main.bundleIdentifier,
            configuredEngine: Bundle.main.object(
                forInfoDictionaryKey: configuredEngineKey) as? String)
    }

    /// Keep both product identities explicit. OS2 must not silently fall back
    /// to WebKit or reuse the legacy product's browser profile directory.
    static func productionSupportDirectory(for bundleIdentifier: String?) -> String? {
        switch bundleIdentifier {
        case productionBundleIdentifier: return "Tatwo Ultrawork"
        case tatwo2ProductionBundleIdentifier: return "tatwo2"
        default: return nil
        }
    }

    static func helperAppName(bundleIdentifier: String?, bundleName: String?) -> String {
        // build-app.sh stages the helper under its stable product name, then
        // changes the visible CFBundleName to "TATWO OS". Display text is not a path.
        let product = bundleIdentifier == tatwo2ProductionBundleIdentifier
            ? "tatwo2" : (bundleName ?? "Tatwo Ultrawork Staging")
        return "\(product) Helper.app"
    }

    static func helperExecutableURL(in bundle: Bundle) -> URL? {
        guard let helperURL = bundle.privateFrameworksURL?.appendingPathComponent(
            helperAppName(bundleIdentifier: bundle.bundleIdentifier,
                          bundleName: bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)),
              let executable = Bundle(url: helperURL)?.executableURL,
              FileManager.default.isExecutableFile(atPath: executable.path) else { return nil }
        // The packager renames the executable as well as the helper bundle.
        // Resolve CFBundleExecutable instead of assuming the SwiftPM product name.
        return executable
    }
}

struct TatwoCEFProfileLocation: Equatable, Sendable {
    let rootCachePath: String
    let authorityStagingRootPath: String?
    let persistentProfilePath: String?
    let persistentProfileIdentifier: UUID?
    let profilePolicyTag: BrowserProfilePolicyTag
    let helperExecutablePath: String
    let logFilePath: String
}

enum TatwoCEFProfileStoreError: Error, Equatable {
    case invalidCanonicalIdentifier
    case pathEscapesRootCache
    case invalidEpoch
    case epochOverflow
    case unsafeProfileLeaf(path: String)
    case unsafeLegacyProfileLeaf(path: String)
    case legacyProfileContainsData(path: String)
    case legacyEmptyProfileRelocationFailed(path: String)
    case preparedProfilePathMismatch(expected: String, actual: String)
}

struct TatwoCEFLegacyEmptyProfileRelocationReceipt:
    Codable,
    Equatable,
    Sendable
{
    static let schema = "TatwoCEFLegacyEmptyProfileRelocationReceiptV2"

    let schema: String
    let createdAt: Date
    let profileIdentifier: UUID
    let generation: UInt64
    let originalRelativeLeaf: String
    let relocatedRelativeLeaf: String

    init(
        createdAt: Date,
        profileIdentifier: UUID,
        generation: UInt64,
        originalRelativeLeaf: String,
        relocatedRelativeLeaf: String
    ) {
        schema = Self.schema
        self.createdAt = createdAt
        self.profileIdentifier = profileIdentifier
        self.generation = generation
        self.originalRelativeLeaf = originalRelativeLeaf
        self.relocatedRelativeLeaf = relocatedRelativeLeaf
    }
}

struct TatwoCEFProfileStore: Sendable {
    private static let flatProfileLeafPrefix = "tatwo-profile-"
    private static let flatProfileLeafGenerationMarker = "-generation-"

    let rootCacheURL: URL

    static var live: TatwoCEFProfileStore? {
        TatwoCEFProfileLocationResolver.rootCacheURL()
            .map(TatwoCEFProfileStore.init(rootCacheURL:))
    }

    func profileURL(for identifier: UUID) throws -> URL {
        let stableID = try canonicalIdentifier(identifier)
        let generation = try currentGeneration(for: stableID)
        return try profileURL(
            stableIdentifier: stableID,
            generation: generation)
    }

    func profileURL(
        for identifier: UUID,
        generation: UInt64
    ) throws -> URL {
        try profileURL(
            stableIdentifier: canonicalIdentifier(identifier),
            generation: generation)
    }

    private func profileURL(
        stableIdentifier: String,
        generation: UInt64
    ) throws -> URL {
        let candidate = canonicalRootCacheURL
            .appendingPathComponent(
                Self.flatProfileLeaf(
                    stableIdentifier: stableIdentifier,
                    generation: generation),
                isDirectory: true)
            .standardizedFileURL
        let canonicalCandidate =
            Self.canonicalizedPreservingMissingSuffix(candidate)
        guard Self.isDescendant(
                canonicalCandidate,
                of: canonicalRootCacheURL),
              !Self.containsSymbolicLink(
                in: candidate,
                below: canonicalRootCacheURL),
              canonicalCandidate.path == candidate.path
        else {
            throw TatwoCEFProfileStoreError.pathEscapesRootCache
        }
        return canonicalCandidate
    }

    static func parseFlatProfileLeaf(
        _ leaf: String
    ) -> (identifier: UUID, generation: UInt64)? {
        guard leaf.hasPrefix(flatProfileLeafPrefix),
              let markerRange = leaf.range(
                of: flatProfileLeafGenerationMarker,
                options: .backwards),
              markerRange.lowerBound
                > leaf.index(
                    leaf.startIndex,
                    offsetBy: flatProfileLeafPrefix.count)
        else {
            return nil
        }
        let identifierStart = leaf.index(
            leaf.startIndex,
            offsetBy: flatProfileLeafPrefix.count)
        let identifierString = String(
            leaf[identifierStart..<markerRange.lowerBound])
        let generationString = String(leaf[markerRange.upperBound...])
        guard let identifier = UUID(uuidString: identifierString),
              identifier.uuidString.lowercased()
                == identifierString.lowercased(),
              let generation = UInt64(generationString),
              leaf == flatProfileLeaf(
                  stableIdentifier: identifier.uuidString.lowercased(),
                  generation: generation)
        else {
            return nil
        }
        return (identifier, generation)
    }

    private static func flatProfileLeaf(
        stableIdentifier: String,
        generation: UInt64
    ) -> String {
        "\(flatProfileLeafPrefix)\(stableIdentifier)"
            + "\(flatProfileLeafGenerationMarker)\(generation)"
    }

    /// CEF's Chrome runtime accepts a request-context cache path only when it is
    /// equal to `root_cache_path` or an immediate child of it. Keep every
    /// session generation as one flat child of the shared root. The directory
    /// may already exist when reopening a persistent profile; CEF owns its
    /// contents, while Tatwo only validates the path and prepares the root.
    @discardableResult
    func prepareProfileParent(for identifier: UUID) throws -> URL {
        let stableID = try canonicalIdentifier(identifier)
        let generation = try currentGeneration(for: stableID)
        let profileURL = try profileURL(
            stableIdentifier: stableID,
            generation: generation)
        let legacyProfileURL = try legacyNestedProfileURL(
            stableIdentifier: stableID,
            generation: generation)
        try relocateLegacyEmptyProfileLeafIfNeeded(
            legacyProfileURL,
            identifier: identifier,
            stableIdentifier: stableID,
            generation: generation)
        try validateExistingProfileLeaf(profileURL)
        guard profileURL.deletingLastPathComponent().path
                == canonicalRootCacheURL.path
        else {
            throw TatwoCEFProfileStoreError.pathEscapesRootCache
        }
        try FileManager.default.createDirectory(
            at: canonicalRootCacheURL,
            withIntermediateDirectories: true)
        return profileURL
    }

    private func validateExistingProfileLeaf(_ profileURL: URL) throws {
        guard Self.pathEntryExists(profileURL) else {
            return
        }
        let values: URLResourceValues
        do {
            values = try profileURL.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        } catch {
            throw TatwoCEFProfileStoreError.unsafeProfileLeaf(
                path: profileURL.path)
        }
        guard values.isDirectory == true,
              values.isSymbolicLink != true,
              !Self.containsSymbolicLink(
                in: profileURL,
                below: canonicalRootCacheURL)
        else {
            throw TatwoCEFProfileStoreError.unsafeProfileLeaf(
                path: profileURL.path)
        }
    }

    /// Early Chromium staging builds used
    /// `root/profiles/<session>/generation-N`, which CEF Chrome runtime rejects
    /// because it is not an immediate child of `root_cache_path`. Only an
    /// actually empty legacy directory is relocated. A populated legacy profile
    /// may contain cookies/login/cache state, so preparation fails closed
    /// without moving, rewriting, or silently abandoning it.
    private func relocateLegacyEmptyProfileLeafIfNeeded(
        _ profileURL: URL,
        identifier: UUID,
        stableIdentifier: String,
        generation: UInt64
    ) throws {
        let fileManager = FileManager.default
        guard Self.pathEntryExists(profileURL) else {
            return
        }
        let resourceValues: URLResourceValues
        do {
            resourceValues = try profileURL.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        } catch {
            throw TatwoCEFProfileStoreError.unsafeLegacyProfileLeaf(
                path: profileURL.path)
        }
        guard resourceValues.isDirectory == true,
              resourceValues.isSymbolicLink != true,
              !Self.containsSymbolicLink(
                in: profileURL,
                below: canonicalRootCacheURL)
        else {
            throw TatwoCEFProfileStoreError.unsafeLegacyProfileLeaf(
                path: profileURL.path)
        }

        let entries: [URL]
        do {
            entries = try fileManager.contentsOfDirectory(
                at: profileURL,
                includingPropertiesForKeys: nil,
                options: [])
        } catch {
            throw TatwoCEFProfileStoreError.unsafeLegacyProfileLeaf(
                path: profileURL.path)
        }
        guard entries.isEmpty else {
            throw TatwoCEFProfileStoreError.legacyProfileContainsData(
                path: profileURL.path)
        }

        let relocationID = UUID().uuidString.lowercased()
        let relocationDirectory = canonicalRootCacheURL
            .appendingPathComponent(
                "legacy-empty-profile-relocations",
                isDirectory: true)
            .appendingPathComponent(
                stableIdentifier,
                isDirectory: true)
            .appendingPathComponent(
                "generation-\(generation)-\(relocationID)",
                isDirectory: true)
            .standardizedFileURL
        let relocatedLeaf = relocationDirectory
            .appendingPathComponent("profile-leaf", isDirectory: true)
            .standardizedFileURL
        guard Self.isDescendant(
                relocationDirectory,
                of: canonicalRootCacheURL),
              Self.isDescendant(relocatedLeaf, of: canonicalRootCacheURL),
              !Self.containsSymbolicLink(
                in: relocationDirectory,
                below: canonicalRootCacheURL)
        else {
            throw TatwoCEFProfileStoreError.pathEscapesRootCache
        }

        do {
            try fileManager.createDirectory(
                at: relocationDirectory,
                withIntermediateDirectories: true)
            let receipt = TatwoCEFLegacyEmptyProfileRelocationReceipt(
                createdAt: Date(),
                profileIdentifier: identifier,
                generation: generation,
                originalRelativeLeaf: [
                    "profiles",
                    stableIdentifier,
                    "generation-\(generation)",
                ].joined(separator: "/"),
                relocatedRelativeLeaf: [
                    "legacy-empty-profile-relocations",
                    stableIdentifier,
                    relocationDirectory.lastPathComponent,
                    "profile-leaf",
                ].joined(separator: "/"))
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .millisecondsSince1970
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(receipt).write(
                to: relocationDirectory
                    .appendingPathComponent("receipt.json"),
                options: .atomic)
            try fileManager.moveItem(at: profileURL, to: relocatedLeaf)
        } catch {
            throw TatwoCEFProfileStoreError
                .legacyEmptyProfileRelocationFailed(path: profileURL.path)
        }
    }

    private func legacyNestedProfileURL(
        stableIdentifier: String,
        generation: UInt64
    ) throws -> URL {
        let candidate = canonicalRootCacheURL
            .appendingPathComponent("profiles", isDirectory: true)
            .appendingPathComponent(
                stableIdentifier,
                isDirectory: true)
            .appendingPathComponent(
                "generation-\(generation)",
                isDirectory: true)
            .standardizedFileURL
        let canonicalCandidate =
            Self.canonicalizedPreservingMissingSuffix(candidate)
        guard Self.isDescendant(
                canonicalCandidate,
                of: canonicalRootCacheURL),
              !Self.containsSymbolicLink(
                in: candidate,
                below: canonicalRootCacheURL),
              canonicalCandidate.path == candidate.path
        else {
            throw TatwoCEFProfileStoreError.pathEscapesRootCache
        }
        return canonicalCandidate
    }

    @discardableResult
    func rotateProfile(for identifier: UUID) throws -> URL {
        let stableID = try canonicalIdentifier(identifier)
        let current = try currentGeneration(for: stableID)
        guard current < UInt64.max else {
            throw TatwoCEFProfileStoreError.epochOverflow
        }
        let previousURL = try profileURL(for: identifier)
        let epochFile = epochFileURL(for: stableID)
        try FileManager.default.createDirectory(
            at: epochFile.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data("\(current + 1)\n".utf8)
            .write(to: epochFile, options: .atomic)
        return previousURL
    }

    func currentGeneration(for identifier: UUID) throws -> UInt64 {
        try currentGeneration(for: canonicalIdentifier(identifier))
    }

    private var canonicalRootCacheURL: URL {
        Self.canonicalizedPreservingMissingSuffix(rootCacheURL)
    }

    private func canonicalIdentifier(_ identifier: UUID) throws -> String {
        let stableID = identifier.uuidString.lowercased()
        guard UUID(uuidString: stableID)?
            .uuidString.lowercased() == stableID
        else {
            throw TatwoCEFProfileStoreError.invalidCanonicalIdentifier
        }
        return stableID
    }

    private func currentGeneration(for stableID: String) throws -> UInt64 {
        let epochFile = epochFileURL(for: stableID)
        guard FileManager.default.fileExists(atPath: epochFile.path) else {
            return 0
        }
        let rawValue = try String(contentsOf: epochFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = UInt64(rawValue) else {
            throw TatwoCEFProfileStoreError.invalidEpoch
        }
        return value
    }

    private func epochFileURL(for stableID: String) -> URL {
        canonicalRootCacheURL
            .appendingPathComponent("profile-epochs", isDirectory: true)
            .appendingPathComponent("\(stableID).txt")
    }

    /// `URL.resolvingSymlinksInPath()` can return a different spelling before
    /// and after a missing descendant is created (for example `/var` versus
    /// `/private/var`). Resolve only the deepest existing path entry, then
    /// append the absent suffix unchanged so profile identity stays stable.
    ///
    /// A symlink counts as an existing entry even when its destination is
    /// missing. Callers compare the result with the lexical candidate, causing
    /// any profile-path symlink redirection to fail closed.
    private static func canonicalizedPreservingMissingSuffix(
        _ url: URL
    ) -> URL {
        var existingAncestor = url.standardizedFileURL
        var missingComponents: [String] = []
        while !pathEntryExists(existingAncestor) {
            let parent = existingAncestor.deletingLastPathComponent()
            guard parent.path != existingAncestor.path else {
                break
            }
            missingComponents.append(existingAncestor.lastPathComponent)
            existingAncestor = parent
        }
        var canonical = existingAncestor.resolvingSymlinksInPath()
        for component in missingComponents.reversed() {
            canonical.appendPathComponent(component, isDirectory: false)
        }
        return URL(
            fileURLWithPath: canonical.path,
            isDirectory: false)
            .standardizedFileURL
    }

    private static func pathEntryExists(_ url: URL) -> Bool {
        if FileManager.default.fileExists(atPath: url.path) {
            return true
        }
        return (try? FileManager.default.destinationOfSymbolicLink(
            atPath: url.path)) != nil
    }

    private static func containsSymbolicLink(
        in child: URL,
        below parent: URL
    ) -> Bool {
        let childComponents = child.standardizedFileURL.pathComponents
        let parentComponents = parent.standardizedFileURL.pathComponents
        guard childComponents.count > parentComponents.count,
              Array(childComponents.prefix(parentComponents.count))
                == parentComponents
        else {
            return true
        }
        var candidate = parent.standardizedFileURL
        for component in childComponents.dropFirst(parentComponents.count) {
            candidate.appendPathComponent(component)
            if (try? FileManager.default.destinationOfSymbolicLink(
                atPath: candidate.path)) != nil
            {
                return true
            }
        }
        return false
    }

    static func isDescendant(_ child: URL, of parent: URL) -> Bool {
        let childComponents = child.standardizedFileURL.pathComponents
        let parentComponents = parent.standardizedFileURL.pathComponents
        guard childComponents.count > parentComponents.count else {
            return false
        }
        return Array(childComponents.prefix(parentComponents.count))
            == parentComponents
    }
}

enum TatwoCEFDirectorySizeError: Error, Equatable {
    case invalidDirectory
    case byteCountOverflow
}

enum TatwoCEFDirectorySize {
    static func measuredAllocatedBytes(
        at directoryURL: URL,
        containedIn rootURL: URL,
        fileManager: FileManager = .default
    ) throws -> UInt64 {
        guard fileManager.fileExists(atPath: directoryURL.path) else {
            return 0
        }
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .totalFileAllocatedSizeKey,
            .fileAllocatedSizeKey,
        ]
        let canonicalRoot = rootURL.standardizedFileURL
            .resolvingSymlinksInPath()
        let canonicalDirectory = directoryURL.standardizedFileURL
            .resolvingSymlinksInPath()
        let directoryValues = try directoryURL.resourceValues(forKeys: keys)
        guard directoryValues.isDirectory == true,
              directoryValues.isSymbolicLink != true,
              TatwoCEFProfileStore.isDescendant(
                canonicalDirectory,
                of: canonicalRoot),
              canonicalDirectory.path
                == directoryURL.standardizedFileURL.path
        else {
            throw TatwoCEFDirectorySizeError.invalidDirectory
        }

        var enumerationFailed = false
        guard let enumerator = fileManager.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, _ in
                enumerationFailed = true
                return false
            })
        else {
            throw TatwoCEFDirectorySizeError.invalidDirectory
        }

        var total: UInt64 = 0
        for case let fileURL as URL in enumerator {
            guard !enumerationFailed else {
                throw TatwoCEFDirectorySizeError.invalidDirectory
            }
            let values = try fileURL.resourceValues(forKeys: keys)
            let canonicalFile = fileURL.standardizedFileURL
                .resolvingSymlinksInPath()
            guard values.isSymbolicLink != true,
                  TatwoCEFProfileStore.isDescendant(
                    canonicalFile,
                    of: canonicalRoot)
            else {
                throw TatwoCEFDirectorySizeError.invalidDirectory
            }
            guard values.isRegularFile == true else {
                continue
            }
            let size =
                values.totalFileAllocatedSize
                ?? values.fileAllocatedSize
                ?? 0
            guard size >= 0 else {
                throw TatwoCEFDirectorySizeError.byteCountOverflow
            }
            let addition = total.addingReportingOverflow(UInt64(size))
            guard !addition.overflow else {
                throw TatwoCEFDirectorySizeError.byteCountOverflow
            }
            total = addition.partialValue
        }
        guard !enumerationFailed else {
            throw TatwoCEFDirectorySizeError.invalidDirectory
        }
        return total
    }
}

enum TatwoCEFProfileLeaseError: Error, Equatable {
    case profileBlockedForPurge
    case profileInUse
    case invalidProfilePath
    case unknownLease
}

enum TatwoCEFProfileAvailabilityWaitOutcome: Equatable, Sendable {
    case available
    case timedOut
    case cancelled
}

enum TatwoCEFProfilePurgeError: Error, Equatable {
    case profileInUse
    case purgeInProgress
    case invalidProfilePath
}

enum TatwoCEFOriginDataClearError: Error, Equatable, Sendable {
    case invalidOrigin
    case profileInUse
    case maintenanceInProgress
    case invalidProfilePath
    case runtimeUnavailable
    case bridgeUnavailable
    case cookieClearFailed(receipt: TatwoCEFOriginDataClearReceipt)
    case originStorageClearFailed(
        code: Int,
        receipt: TatwoCEFOriginDataClearReceipt)
    case bridgeRejected(
        code: Int,
        receipt: TatwoCEFOriginDataClearReceipt)
}

enum TatwoCEFHTTPResponseCacheClearStatus: String, Equatable, Sendable {
    case unsupported
}

struct TatwoCEFOriginDataClearReceipt: Equatable, Sendable {
    let cookiesCleared: Bool
    let originStorageCleared: Bool
    let httpResponseCacheStatus: TatwoCEFHTTPResponseCacheClearStatus

    var siteDataCleared: Bool {
        cookiesCleared && originStorageCleared
    }
}

enum TatwoCEFOriginDataClearBridge {
    typealias Completion = @Sendable (
        Result<
            TatwoCEFOriginDataClearReceipt,
            TatwoCEFOriginDataClearError
        >
    ) -> Void

    static func clear(
        origin: String,
        persistentProfilePath: String,
        completion: @escaping Completion
    ) {
        guard TatwoCEFRuntime.compiled else {
            completion(.failure(.runtimeUnavailable))
            return
        }
        let selector = NSSelectorFromString(
            "clearDataForOrigin:persistentProfile:completion:")
        guard TatwoCEFRuntime.responds(to: selector) else {
            completion(.failure(.bridgeUnavailable))
            return
        }
        guard TatwoCEFRuntime.supportsOriginScopedSiteDataClearing else {
            completion(.failure(.bridgeUnavailable))
            return
        }
        TatwoCEFRuntime.clearData(
            forOrigin: origin,
            persistentProfile: persistentProfilePath
        ) { cookiesCleared,
            originStorageCleared,
            httpResponseCacheUnsupported,
            error in
            let receipt = TatwoCEFOriginDataClearReceipt(
                cookiesCleared: cookiesCleared,
                originStorageCleared: originStorageCleared,
                httpResponseCacheStatus: .unsupported)
            guard httpResponseCacheUnsupported else {
                completion(
                    .failure(
                        .bridgeRejected(
                            code: -1,
                            receipt: receipt)))
                return
            }
            guard let error else {
                completion(.success(receipt))
                return
            }
            let errorCode = (error as NSError).code
            switch errorCode {
            case 30:
                completion(.failure(.runtimeUnavailable))
            case 31:
                completion(.failure(.invalidOrigin))
            case 32:
                completion(.failure(.invalidProfilePath))
            case 33, 34:
                completion(
                    .failure(
                        .cookieClearFailed(receipt: receipt)))
            case 35, 36, 37, 38:
                completion(
                    .failure(
                        .originStorageClearFailed(
                            code: errorCode,
                            receipt: receipt)))
            default:
                completion(
                    .failure(
                        .bridgeRejected(
                            code: errorCode,
                            receipt: receipt)))
            }
        }
    }
}

private final class TatwoCEFOriginDataClearCallbackGate:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var didClaimTerminalResult = false

    func claimTerminalResult() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !didClaimTerminalResult else { return false }
        didClaimTerminalResult = true
        return true
    }
}

@MainActor
final class TatwoCEFProfileLeaseRegistry {
    static let shared = TatwoCEFProfileLeaseRegistry()
    static let defaultAvailabilityWaitTimeoutNanoseconds: UInt64 =
        8_000_000_000

    struct Lease: Equatable, Sendable {
        let identifier: UUID
        let token: UUID
        let profileURL: URL
    }

    struct PurgeReservation: Equatable, Sendable {
        let identifier: UUID
        let token: UUID
    }

    struct OriginClearReservation: Equatable, Sendable {
        let identifier: UUID
        let token: UUID
        let origin: String
        let profileURL: URL
        let retriesFailure: Bool
    }

    typealias ProfileDisposer =
        (URL, @escaping (Error?) -> Void) -> Void
    typealias OriginDataClearCompletion = @MainActor @Sendable (
        Result<
            TatwoCEFOriginDataClearReceipt,
            TatwoCEFOriginDataClearError
        >
    ) -> Void
    typealias OriginDataClearer = @Sendable (
        String,
        String,
        @escaping @Sendable (
            Result<
                TatwoCEFOriginDataClearReceipt,
                TatwoCEFOriginDataClearError
            >
        ) -> Void
    ) -> Void

    private enum MaintenanceState: Equatable {
        case reserved(token: UUID, pendingProfileURL: URL?)
        case purging(token: UUID, profileURL: URL)
        case failed(profileURL: URL?)
        case originClearReserved(
            token: UUID,
            origin: String,
            profileURL: URL)
        case originClearing(
            token: UUID,
            origin: String,
            profileURL: URL)
        case originClearFailed(origin: String, profileURL: URL)
    }

    private struct AvailabilityWaiter {
        let continuation: CheckedContinuation<
            TatwoCEFProfileAvailabilityWaitOutcome,
            Never
        >
        let timeoutTask: Task<Void, Never>
    }

    private var leases: [UUID: Set<UUID>] = [:]
    private var maintenance: [UUID: MaintenanceState] = [:]
    private var availabilityWaiters: [
        UUID: [UUID: AvailabilityWaiter]
    ] = [:]

    func acquire(
        identifier: UUID,
        profileURL: URL
    ) -> Result<Lease, TatwoCEFProfileLeaseError> {
        guard maintenance[identifier] == nil else {
            return .failure(.profileBlockedForPurge)
        }
        guard leases[identifier]?.isEmpty != false else {
            return .failure(.profileInUse)
        }
        guard Self.profileURL(profileURL, contains: identifier) else {
            return .failure(.invalidProfilePath)
        }
        let token = UUID()
        leases[identifier, default: []].insert(token)
        return .success(
            Lease(
                identifier: identifier,
                token: token,
                profileURL: profileURL))
    }

    @discardableResult
    func release(_ lease: Lease) -> Bool {
        guard var tokens = leases[lease.identifier],
              tokens.remove(lease.token) != nil
        else {
            return false
        }
        if tokens.isEmpty {
            leases.removeValue(forKey: lease.identifier)
            let waiters = availabilityWaiters.removeValue(
                forKey: lease.identifier) ?? [:]
            waiters.values.forEach { waiter in
                waiter.timeoutTask.cancel()
                waiter.continuation.resume(returning: .available)
            }
        } else {
            leases[lease.identifier] = tokens
        }
        return true
    }

    func waitUntilAvailable(
        identifier: UUID,
        timeoutNanoseconds: UInt64 =
            TatwoCEFProfileLeaseRegistry
                .defaultAvailabilityWaitTimeoutNanoseconds
    ) async -> TatwoCEFProfileAvailabilityWaitOutcome {
        guard !Task.isCancelled else {
            return .cancelled
        }
        guard leases[identifier]?.isEmpty == false else {
            return .available
        }

        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: .cancelled)
                    return
                }
                guard leases[identifier]?.isEmpty == false else {
                    continuation.resume(returning: .available)
                    return
                }
                let timeoutTask = Task { @MainActor [weak self] in
                    do {
                        try await Task.sleep(
                            nanoseconds: timeoutNanoseconds)
                    } catch {
                        return
                    }
                    self?.resolveAvailabilityWaiter(
                        identifier: identifier,
                        waiterID: waiterID,
                        outcome: .timedOut)
                }
                availabilityWaiters[identifier, default: [:]][waiterID] =
                    AvailabilityWaiter(
                        continuation: continuation,
                        timeoutTask: timeoutTask)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.resolveAvailabilityWaiter(
                    identifier: identifier,
                    waiterID: waiterID,
                    outcome: .cancelled)
            }
        }
    }

    private func resolveAvailabilityWaiter(
        identifier: UUID,
        waiterID: UUID,
        outcome: TatwoCEFProfileAvailabilityWaitOutcome
    ) {
        guard var waiters = availabilityWaiters[identifier],
              let waiter = waiters.removeValue(forKey: waiterID)
        else {
            return
        }
        if waiters.isEmpty {
            availabilityWaiters.removeValue(forKey: identifier)
        } else {
            availabilityWaiters[identifier] = waiters
        }
        if outcome != .timedOut {
            waiter.timeoutTask.cancel()
        }
        waiter.continuation.resume(returning: outcome)
    }

    func reservePurge(
        identifier: UUID
    ) -> Result<PurgeReservation, TatwoCEFProfilePurgeError> {
        guard leases[identifier]?.isEmpty != false else {
            return .failure(.profileInUse)
        }
        let pendingProfileURL: URL?
        switch maintenance[identifier] {
        case nil:
            pendingProfileURL = nil
        case let .failed(profileURL):
            pendingProfileURL = profileURL
        case .reserved, .purging,
             .originClearReserved, .originClearing, .originClearFailed:
            return .failure(.purgeInProgress)
        }
        let token = UUID()
        maintenance[identifier] = .reserved(
            token: token,
            pendingProfileURL: pendingProfileURL)
        return .success(
            PurgeReservation(identifier: identifier, token: token))
    }

    func cancelPurge(_ reservation: PurgeReservation) {
        guard case let .reserved(token, pendingProfileURL) =
            maintenance[reservation.identifier],
            token == reservation.token
        else {
            return
        }
        if let pendingProfileURL {
            maintenance[reservation.identifier] = .failed(
                profileURL: pendingProfileURL)
        } else {
            maintenance.removeValue(forKey: reservation.identifier)
        }
    }

    /// Releases a capacity-enforcement reservation after the exact archived
    /// generation has been reversibly disposed. Unlike `commitPurge`, this
    /// does not rotate the current generation because capacity eviction
    /// targets an already archived row rather than the live session profile.
    @discardableResult
    func completeReservedPurge(_ reservation: PurgeReservation) -> Bool {
        guard case let .reserved(token, _) =
            maintenance[reservation.identifier],
            token == reservation.token
        else {
            return false
        }
        maintenance.removeValue(forKey: reservation.identifier)
        return true
    }

    func reserveOriginDataClear(
        identifier: UUID,
        origin: String,
        profileURL: URL
    ) -> Result<OriginClearReservation, TatwoCEFOriginDataClearError> {
        guard let canonicalOrigin = Self.canonicalOrigin(origin) else {
            return .failure(.invalidOrigin)
        }
        guard Self.profileURL(profileURL, contains: identifier) else {
            return .failure(.invalidProfilePath)
        }
        guard leases[identifier]?.isEmpty != false else {
            return .failure(.profileInUse)
        }

        let retriesFailure: Bool
        switch maintenance[identifier] {
        case nil:
            retriesFailure = false
        case let .originClearFailed(failedOrigin, failedProfileURL)
            where failedOrigin == canonicalOrigin
                && failedProfileURL == profileURL:
            retriesFailure = true
        case .reserved, .purging, .failed,
             .originClearReserved, .originClearing, .originClearFailed:
            return .failure(.maintenanceInProgress)
        }

        let token = UUID()
        maintenance[identifier] = .originClearReserved(
            token: token,
            origin: canonicalOrigin,
            profileURL: profileURL)
        return .success(
            OriginClearReservation(
                identifier: identifier,
                token: token,
                origin: canonicalOrigin,
                profileURL: profileURL,
                retriesFailure: retriesFailure))
    }

    func cancelOriginDataClear(_ reservation: OriginClearReservation) {
        guard maintenance[reservation.identifier]
            == .originClearReserved(
                token: reservation.token,
                origin: reservation.origin,
                profileURL: reservation.profileURL)
        else {
            return
        }
        if reservation.retriesFailure {
            maintenance[reservation.identifier] = .originClearFailed(
                origin: reservation.origin,
                profileURL: reservation.profileURL)
        } else {
            maintenance.removeValue(forKey: reservation.identifier)
        }
    }

    func commitOriginDataClear(
        _ reservation: OriginClearReservation,
        store: TatwoCEFProfileStore,
        clearer: @escaping OriginDataClearer = { origin, profilePath, completion in
            TatwoCEFOriginDataClearBridge.clear(
                origin: origin,
                persistentProfilePath: profilePath,
                completion: completion)
        },
        completion: @escaping OriginDataClearCompletion
    ) {
        guard maintenance[reservation.identifier]
            == .originClearReserved(
                token: reservation.token,
                origin: reservation.origin,
                profileURL: reservation.profileURL)
        else {
            completion(.failure(.maintenanceInProgress))
            return
        }
        guard (try? store.profileURL(for: reservation.identifier))
            == reservation.profileURL
        else {
            maintenance[reservation.identifier] = .originClearFailed(
                origin: reservation.origin,
                profileURL: reservation.profileURL)
            completion(.failure(.invalidProfilePath))
            return
        }

        maintenance[reservation.identifier] = .originClearing(
            token: reservation.token,
            origin: reservation.origin,
            profileURL: reservation.profileURL)
        let callbackGate = TatwoCEFOriginDataClearCallbackGate()
        clearer(
            reservation.origin,
            reservation.profileURL.path
        ) { result in
            guard callbackGate.claimTerminalResult() else {
                return
            }
            Task { @MainActor in
                guard self.maintenance[reservation.identifier]
                        == .originClearing(
                            token: reservation.token,
                            origin: reservation.origin,
                            profileURL: reservation.profileURL)
                else {
                    return
                }
                switch result {
                case .success:
                    self.maintenance.removeValue(
                        forKey: reservation.identifier)
                case .failure:
                    self.maintenance[reservation.identifier] =
                        .originClearFailed(
                            origin: reservation.origin,
                            profileURL: reservation.profileURL)
                }
                completion(result)
            }
        }
    }

    func commitPurge(
        _ reservation: PurgeReservation,
        store: TatwoCEFProfileStore,
        disposer: @escaping ProfileDisposer = { url, completion in
            guard FileManager.default.fileExists(atPath: url.path) else {
                completion(nil)
                return
            }
            do {
                var resultingURL: NSURL?
                try FileManager.default.trashItem(
                    at: url,
                    resultingItemURL: &resultingURL)
                completion(nil)
            } catch {
                completion(error)
            }
        },
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard case let .reserved(token, pendingProfileURL) =
            maintenance[reservation.identifier],
            token == reservation.token
        else {
            completion(
                .failure(
                    TatwoCEFProfilePurgeError.purgeInProgress))
            return
        }

        let previousURL: URL
        if let pendingProfileURL {
            // A failed disposal retry must target the exact generation that
            // failed previously. Rotating again would strand the original
            // cookie/login directory while only attempting to remove a new,
            // usually empty generation.
            previousURL = pendingProfileURL
        } else {
            do {
                // Epoch rotation happens before disposal. Even if Trash is
                // temporarily unavailable, a reused session ID cannot inherit
                // cookies or login state from the previous CEF request context.
                previousURL = try store.rotateProfile(
                    for: reservation.identifier)
            } catch {
                maintenance[reservation.identifier] = .failed(profileURL: nil)
                completion(.failure(error))
                return
            }
        }
        maintenance[reservation.identifier] = .purging(
            token: reservation.token,
            profileURL: previousURL)

        disposer(previousURL) { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self,
                      self.maintenance[reservation.identifier]
                        == .purging(
                            token: reservation.token,
                            profileURL: previousURL)
                else {
                    return
                }
                if let error {
                    self.maintenance[reservation.identifier] = .failed(
                        profileURL: previousURL)
                    completion(.failure(error))
                } else {
                    self.maintenance.removeValue(
                        forKey: reservation.identifier)
                    completion(.success(()))
                }
            }
        }
    }

    func isBlocked(_ identifier: UUID) -> Bool {
        maintenance[identifier] != nil
    }

    func activeLeaseCount(for identifier: UUID) -> Int {
        leases[identifier]?.count ?? 0
    }

    var activeProfileIdentifiers: Set<UUID> {
        Set(leases.keys)
    }

    func resetForTesting() {
        leases.removeAll()
        maintenance.removeAll()
        let waiters = availabilityWaiters.values.flatMap(\.values)
        availabilityWaiters.removeAll()
        waiters.forEach { waiter in
            waiter.timeoutTask.cancel()
            waiter.continuation.resume(returning: .cancelled)
        }
    }

    private static func canonicalOrigin(_ rawValue: String) -> String? {
        guard var components = URLComponents(string: rawValue),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host?.lowercased(),
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/"
        else {
            return nil
        }
        components.scheme = scheme
        components.host = host
        components.path = ""
        guard let canonical = components.string else {
            return nil
        }
        return canonical
    }

    private static func profileURL(
        _ profileURL: URL,
        contains identifier: UUID
    ) -> Bool {
        let canonicalID = identifier.uuidString.lowercased()
        let prefix = "tatwo-profile-\(canonicalID)-generation-"
        let leaf = profileURL.standardizedFileURL.lastPathComponent
        guard leaf.hasPrefix(prefix) else {
            return false
        }
        return UInt64(leaf.dropFirst(prefix.count)) != nil
    }
}

enum TatwoCEFProfileCeilingError: Error, Equatable {
    case invalidByteCeiling
    case corruptLedger
    case byteCountOverflow
    case invalidProfilePath(identifier: UUID, generation: UInt64)
    case ceilingUnsatisfied(totalBytes: UInt64, byteCeiling: UInt64)
    case reversibleDisposalFailed(identifier: UUID, generation: UInt64)
}

struct TatwoCEFProfileCeilingResult: Equatable, Sendable {
    let bytesBefore: UInt64
    let bytesAfter: UInt64
    let evictedProfiles: [TatwoCEFProfileCapacityRowKey]
    let evictedLedgerRows: [TatwoCEFProfileCapacityRowKey]
    let reconciledMissingLedgerRowCount: Int
}

struct TatwoCEFProfileCapacityRowKey: Equatable, Hashable, Sendable {
    let profileIdentifier: UUID
    let generation: UInt64
    let storageKind: EmbeddedBrowserProfileStorageKind
}

struct TatwoCEFProfileCeilingController: Sendable {
    let store: TatwoCEFProfileStore

    @MainActor
    func enforce(
        byteCeiling: UInt64,
        currentIdentifier: UUID?,
        activeIdentifiers: Set<UUID>,
        ledger: EmbeddedBrowserProfileCapacityLedger,
        leaseRegistry: TatwoCEFProfileLeaseRegistry,
        removeLedgerRecord: (
            TatwoCEFProfileCapacityRowKey
        ) throws -> Void,
        rootDirectoryContents: (URL) throws -> [URL] = {
            try FileManager.default.contentsOfDirectory(
                at: $0,
                includingPropertiesForKeys: [
                    .isDirectoryKey,
                    .isSymbolicLinkKey,
                ],
                options: [])
        },
        profileEntryProbe: (URL) throws -> ProfileEntryExistence =
            defaultProfileEntryProbe,
        disposer: (URL) throws -> Void = { url in
            guard FileManager.default.fileExists(atPath: url.path) else {
                return
            }
            var resultingURL: NSURL?
            try FileManager.default.trashItem(
                at: url,
                resultingItemURL: &resultingURL)
        }
    ) throws -> TatwoCEFProfileCeilingResult {
        guard byteCeiling > 0 else {
            throw TatwoCEFProfileCeilingError.invalidByteCeiling
        }
        guard ledger.schema == EmbeddedBrowserProfileCapacityLedger.schema else {
            throw TatwoCEFProfileCeilingError.corruptLedger
        }
        let rootSnapshot = try validatedRootSnapshot(
            contentsOfDirectory: rootDirectoryContents)
        var identities: Set<String> = []
        var reconciledMissingLedgerRowCount = 0
        var ledgerKeys: Set<TatwoCEFProfileCapacityRowKey> = []
        let rows = try ledger.entries.compactMap { entry -> ProfileRow? in
            guard entry.storageKind == .cefAppOwned else {
                return nil
            }
            let identity =
                "\(entry.profileIdentifier.uuidString):\(entry.generation)"
            guard identities.insert(identity).inserted else {
                throw TatwoCEFProfileCeilingError.corruptLedger
            }
            let url = try validatedProfileURL(
                identifier: entry.profileIdentifier,
                generation: entry.generation)
            let key = TatwoCEFProfileCapacityRowKey(
                profileIdentifier: entry.profileIdentifier,
                generation: entry.generation,
                storageKind: entry.storageKind)
            switch try profileEntryProbe(url) {
            case .present:
                break
            case .missing:
                try removeLedgerRecord(key)
                reconciledMissingLedgerRowCount += 1
                return nil
            }
            ledgerKeys.insert(key)
            return ProfileRow(
                key: key,
                url: url,
                lastAccessedAt: entry.lastAccessedAt,
                isArchived: entry.isArchived,
                pendingArchiveIntentID: entry.pendingArchiveIntentID,
                hasLedgerRecord: true,
                measuredBytes: try measuredBytes(
                    at: url,
                    identifier: entry.profileIdentifier,
                    generation: entry.generation))
        }
        let orphanRows = try orphanProfileRows(
            excluding: ledgerKeys,
            rootSnapshot: rootSnapshot)
        let allRows = rows + orphanRows
        let bytesBefore = try totalBytes(in: allRows)
        guard bytesBefore > byteCeiling else {
            return TatwoCEFProfileCeilingResult(
                bytesBefore: bytesBefore,
                bytesAfter: bytesBefore,
                evictedProfiles: [],
                evictedLedgerRows: [],
                reconciledMissingLedgerRowCount:
                    reconciledMissingLedgerRowCount)
        }

        let candidates = allRows
            .filter { row in
                (row.hasLedgerRecord == false
                    || (row.isArchived
                        && row.pendingArchiveIntentID == nil))
                    && row.key.profileIdentifier != currentIdentifier
                    && !activeIdentifiers.contains(row.key.profileIdentifier)
            }
            .sorted { lhs, rhs in
                // Orphans have no ledger-backed lifecycle state and therefore
                // have the lowest preservation priority.
                if lhs.hasLedgerRecord != rhs.hasLedgerRecord {
                    return lhs.hasLedgerRecord == false
                }
                if lhs.lastAccessedAt != rhs.lastAccessedAt {
                    return lhs.lastAccessedAt < rhs.lastAccessedAt
                }
                if lhs.key.profileIdentifier
                    != rhs.key.profileIdentifier
                {
                    return lhs.key.profileIdentifier.uuidString
                        < rhs.key.profileIdentifier.uuidString
                }
                return lhs.key.generation < rhs.key.generation
            }

        let eligibleBytes = try totalBytes(in: candidates)
        guard bytesBefore - eligibleBytes <= byteCeiling else {
            throw TatwoCEFProfileCeilingError.ceilingUnsatisfied(
                totalBytes: bytesBefore,
                byteCeiling: byteCeiling)
        }

        var bytesAfter = bytesBefore
        var evictedProfiles: [TatwoCEFProfileCapacityRowKey] = []
        var evictedLedgerRows: [TatwoCEFProfileCapacityRowKey] = []
        for candidate in candidates where bytesAfter > byteCeiling {
            let reservation: TatwoCEFProfileLeaseRegistry.PurgeReservation
            switch leaseRegistry.reservePurge(
                identifier: candidate.key.profileIdentifier)
            {
            case let .success(value):
                reservation = value
            case .failure:
                // The stale active snapshot is advisory only. Reservation is
                // the authoritative, mutually exclusive recheck immediately
                // before disposal.
                continue
            }
            do {
                try disposer(candidate.url)
            } catch {
                leaseRegistry.cancelPurge(reservation)
                throw TatwoCEFProfileCeilingError.reversibleDisposalFailed(
                    identifier: candidate.key.profileIdentifier,
                    generation: candidate.key.generation)
            }
            if candidate.hasLedgerRecord {
                do {
                    try removeLedgerRecord(candidate.key)
                } catch {
                    _ = leaseRegistry.completeReservedPurge(reservation)
                    throw TatwoCEFProfileCeilingError
                        .reversibleDisposalFailed(
                            identifier: candidate.key.profileIdentifier,
                            generation: candidate.key.generation)
                }
                evictedLedgerRows.append(candidate.key)
            }
            _ = leaseRegistry.completeReservedPurge(reservation)
            bytesAfter -= candidate.measuredBytes
            evictedProfiles.append(candidate.key)
        }

        guard bytesAfter <= byteCeiling else {
            throw TatwoCEFProfileCeilingError.ceilingUnsatisfied(
                totalBytes: bytesAfter,
                byteCeiling: byteCeiling)
        }

        return TatwoCEFProfileCeilingResult(
            bytesBefore: bytesBefore,
            bytesAfter: bytesAfter,
            evictedProfiles: evictedProfiles,
            evictedLedgerRows: evictedLedgerRows,
            reconciledMissingLedgerRowCount:
                reconciledMissingLedgerRowCount)
    }

    private func totalBytes(
        in rows: [ProfileRow]
    ) throws -> UInt64 {
        var total: UInt64 = 0
        for row in rows {
            let addition = total.addingReportingOverflow(row.measuredBytes)
            guard !addition.overflow else {
                throw TatwoCEFProfileCeilingError.byteCountOverflow
            }
            total = addition.partialValue
        }
        return total
    }

    private func validatedProfileURL(
        identifier: UUID,
        generation: UInt64
    ) throws -> URL {
        do {
            return try store.profileURL(
                for: identifier,
                generation: generation)
        } catch {
            throw TatwoCEFProfileCeilingError.invalidProfilePath(
                identifier: identifier,
                generation: generation)
        }
    }

    private func measuredBytes(
        at profileURL: URL,
        identifier: UUID,
        generation: UInt64
    ) throws -> UInt64 {
        do {
            return try TatwoCEFDirectorySize.measuredAllocatedBytes(
                at: profileURL,
                containedIn: store.rootCacheURL)
        } catch TatwoCEFDirectorySizeError.byteCountOverflow {
            throw TatwoCEFProfileCeilingError.byteCountOverflow
        } catch {
            throw TatwoCEFProfileCeilingError.invalidProfilePath(
                identifier: identifier,
                generation: generation)
        }
    }

    private func orphanProfileRows(
        excluding ledgerKeys: Set<TatwoCEFProfileCapacityRowKey>,
        rootSnapshot: RootSnapshot
    ) throws -> [ProfileRow] {
        let fileManager = FileManager.default
        return try rootSnapshot.children.compactMap { child in
            guard let parsed = TatwoCEFProfileStore.parseFlatProfileLeaf(
                child.lastPathComponent)
            else {
                return nil
            }
            let key = TatwoCEFProfileCapacityRowKey(
                profileIdentifier: parsed.identifier,
                generation: parsed.generation,
                storageKind: .cefAppOwned)
            guard !ledgerKeys.contains(key) else {
                return nil
            }
            let values = try child.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            let canonicalChild = child.standardizedFileURL
                .resolvingSymlinksInPath()
            guard values.isDirectory == true,
                  values.isSymbolicLink != true,
                  (try? fileManager.destinationOfSymbolicLink(
                    atPath: child.path)) == nil,
                  child.deletingLastPathComponent()
                    .standardizedFileURL.path
                    == rootSnapshot.lexicalRoot.path,
                  TatwoCEFProfileStore.isDescendant(
                    canonicalChild,
                    of: rootSnapshot.canonicalRoot),
                  canonicalChild.path == child.standardizedFileURL.path
            else {
                throw TatwoCEFProfileCeilingError.invalidProfilePath(
                    identifier: parsed.identifier,
                    generation: parsed.generation)
            }
            return ProfileRow(
                key: key,
                url: canonicalChild,
                lastAccessedAt: .distantPast,
                isArchived: false,
                pendingArchiveIntentID: nil,
                hasLedgerRecord: false,
                measuredBytes: try measuredBytes(
                    at: canonicalChild,
                    identifier: parsed.identifier,
                    generation: parsed.generation))
        }
    }

    private func validatedRootSnapshot(
        contentsOfDirectory: (URL) throws -> [URL]
    ) throws -> RootSnapshot {
        let lexicalRoot = store.rootCacheURL.standardizedFileURL
        let rootValues = try lexicalRoot.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true,
              rootValues.isSymbolicLink != true
        else {
            throw TatwoCEFProfileCeilingError.corruptLedger
        }
        let children = try contentsOfDirectory(lexicalRoot)
        return RootSnapshot(
            lexicalRoot: lexicalRoot,
            canonicalRoot: lexicalRoot.resolvingSymlinksInPath(),
            children: children)
    }

    private static func defaultProfileEntryProbe(
        _ url: URL
    ) throws -> ProfileEntryExistence {
        var metadata = stat()
        if Darwin.lstat(url.path, &metadata) == 0 {
            return .present
        }
        let failureErrno = errno
        guard failureErrno == ENOENT else {
            throw POSIXError(
                POSIXErrorCode(rawValue: failureErrno) ?? .EIO)
        }
        return .missing
    }

    enum ProfileEntryExistence: Sendable {
        case present
        case missing
    }

    private struct RootSnapshot {
        let lexicalRoot: URL
        let canonicalRoot: URL
        let children: [URL]
    }

    private struct ProfileRow {
        let key: TatwoCEFProfileCapacityRowKey
        let url: URL
        let lastAccessedAt: Date
        let isArchived: Bool
        let pendingArchiveIntentID: UUID?
        let hasLedgerRecord: Bool
        let measuredBytes: UInt64
    }
}

enum TatwoCEFProfileLocationResolver {
    static let productionApplicationSupportDirectoryName = "Tatwo Ultrawork"
    static let productionChromiumDirectoryName = "chromium"

    static func rootCacheURL(
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) -> URL? {
        if bundle.bundleIdentifier?
            .hasPrefix(EmbeddedBrowserEnginePolicy.stagingBundlePrefix) == true
        {
            guard let rawRoot = bundle.object(
                forInfoDictionaryKey:
                    EmbeddedBrowserEnginePolicy.stagingRootKey) as? String,
                  !rawRoot.isEmpty
            else {
                return nil
            }
            return rootCacheURL(
                stagingRootURL: URL(
                    fileURLWithPath: rawRoot,
                    isDirectory: true),
                bundleURL: bundle.bundleURL,
                fileManager: fileManager)
        }
        guard EmbeddedBrowserEnginePolicy.productionSupportDirectory(
            for: bundle.bundleIdentifier) != nil,
              let applicationSupportURL = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask).first
        else {
            return nil
        }
        return productionRootCacheURL(
            applicationSupportURL: applicationSupportURL,
            bundleIdentifier: bundle.bundleIdentifier,
            fileManager: fileManager)
    }

    static func productionRootCacheURL(
        applicationSupportURL: URL,
        bundleIdentifier: String? = EmbeddedBrowserEnginePolicy.productionBundleIdentifier,
        fileManager: FileManager = .default
    ) -> URL? {
        guard let directoryName = EmbeddedBrowserEnginePolicy.productionSupportDirectory(
            for: bundleIdentifier) else { return nil }
        let appSupportRoot = applicationSupportURL
            .appendingPathComponent(
                directoryName,
                isDirectory: true)
            .standardizedFileURL
        let chromiumRoot = appSupportRoot
            .appendingPathComponent(
                productionChromiumDirectoryName,
                isDirectory: true)
            .standardizedFileURL
        let rootCache = chromiumRoot
            .appendingPathComponent("cef-root", isDirectory: true)
            .standardizedFileURL
        let requiredDirectories = [
            appSupportRoot,
            chromiumRoot,
            rootCache,
            chromiumRoot.appendingPathComponent(
                "cef-logs",
                isDirectory: true),
            chromiumRoot.appendingPathComponent(
                "browser-security",
                isDirectory: true),
        ]

        for directory in requiredDirectories {
            if (try? fileManager.destinationOfSymbolicLink(
                atPath: directory.path)) != nil
            {
                return nil
            }
            var isDirectory = ObjCBool(false)
            if fileManager.fileExists(
                atPath: directory.path,
                isDirectory: &isDirectory),
               !isDirectory.boolValue
            {
                return nil
            }
        }
        guard let canonicalRoot = TatwoCanonicalPath.resolvedURL(
            preservingMissingSuffixOf: applicationSupportURL,
            fileManager: fileManager),
              let canonicalCandidate = TatwoCanonicalPath.resolvedURL(
                preservingMissingSuffixOf: rootCache,
                fileManager: fileManager),
              TatwoCEFProfileStore.isDescendant(
                canonicalCandidate,
                of: canonicalRoot)
        else {
            return nil
        }
        do {
            for directory in requiredDirectories {
                try fileManager.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true)
            }
        } catch {
            return nil
        }
        for directory in requiredDirectories {
            if (try? fileManager.destinationOfSymbolicLink(
                atPath: directory.path)) != nil
            {
                return nil
            }
        }
        return rootCache
    }

    static func rootCacheURL(
        stagingRootURL: URL,
        bundleURL: URL,
        fileManager: FileManager = .default
    ) -> URL? {
        let stagingRoot = stagingRootURL
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let canonicalBundle = bundleURL
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard TatwoCEFProfileStore.isDescendant(
            canonicalBundle,
            of: stagingRoot)
        else {
            return nil
        }
        let candidate = stagingRoot
            .appendingPathComponent("runtime", isDirectory: true)
            .appendingPathComponent("cef-root", isDirectory: true)
            .standardizedFileURL
        return validatedAuthorityRoot(
            stagingRootURL: stagingRoot,
            rootCacheURL: candidate,
            fileManager: fileManager)
    }

    static func resolve(
        profile: EmbeddedBrowserRuntimeProfile,
        bundle: Bundle = .main
    ) throws -> TatwoCEFProfileLocation? {
        guard let rootCache = rootCacheURL(bundle: bundle) else {
            return nil
        }
        let runtimeRoot = rootCache.deletingLastPathComponent()
        guard let helperExecutable = EmbeddedBrowserEnginePolicy.helperExecutableURL(in: bundle) else {
            return nil
        }
        let logFile = runtimeRoot
            .appendingPathComponent("cef-logs", isDirectory: true)
            .appendingPathComponent("cef.log")
        let authorityStagingRoot =
            bundle.bundleIdentifier?
                .hasPrefix(
                    EmbeddedBrowserEnginePolicy.stagingBundlePrefix) == true
            ? rootCache
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            : nil

        return try resolve(
            profile: profile,
            rootCacheURL: rootCache,
            authorityStagingRootURL: authorityStagingRoot,
            helperExecutablePath: helperExecutable.path,
            logFilePath: logFile.path)
    }

    /// Purely resolves and validates the runtime-facing location. Profile
    /// relocation and directory creation must remain behind
    /// `prepareForRuntime(_:leaseRegistry:)`, after the persistent lease is
    /// acquired.
    static func resolve(
        profile: EmbeddedBrowserRuntimeProfile,
        rootCacheURL: URL,
        authorityStagingRootURL: URL? = nil,
        helperExecutablePath: String,
        logFilePath: String
    ) throws -> TatwoCEFProfileLocation {
        let persistentProfileIdentifier: UUID?
        let persistentProfileURL: URL?
        let profilePolicyTag: BrowserProfilePolicyTag
        switch profile {
        case let .persistent(identifier):
            persistentProfileIdentifier = identifier
            persistentProfileURL = try TatwoCEFProfileStore(
                rootCacheURL: rootCacheURL)
                .profileURL(for: identifier)
            profilePolicyTag = .humanPersistent
        case .ephemeral:
            // A nil request-context cache path is CEF incognito mode. No
            // cookies, login, localStorage, IndexedDB, or cache are persisted.
            persistentProfileIdentifier = nil
            persistentProfileURL = nil
            profilePolicyTag = .humanEphemeral
        }

        return TatwoCEFProfileLocation(
            rootCachePath: rootCacheURL.path,
            authorityStagingRootPath: authorityStagingRootURL?.path,
            persistentProfilePath: persistentProfileURL?.path,
            persistentProfileIdentifier: persistentProfileIdentifier,
            profilePolicyTag: profilePolicyTag,
            helperExecutablePath: helperExecutablePath,
            logFilePath: logFilePath)
    }

    @discardableResult
    @MainActor
    static func prepareForRuntime(
        _ location: TatwoCEFProfileLocation,
        leaseRegistry: TatwoCEFProfileLeaseRegistry = .shared
    ) throws -> TatwoCEFProfileLeaseRegistry.Lease? {
        let lease: TatwoCEFProfileLeaseRegistry.Lease?
        switch (
            location.persistentProfileIdentifier,
            location.persistentProfilePath
        ) {
        case let (.some(identifier), .some(profilePath)):
            switch leaseRegistry.acquire(
                identifier: identifier,
                profileURL: URL(
                    fileURLWithPath: profilePath,
                    isDirectory: true))
            {
            case let .success(acquiredLease):
                lease = acquiredLease
            case let .failure(error):
                throw error
            }
        case (nil, nil):
            lease = nil
        case (.some, nil), (nil, .some):
            throw TatwoCEFProfileLeaseError.invalidProfilePath
        }

        do {
            try prepareDirectories(for: location)
            return lease
        } catch {
            if let lease {
                leaseRegistry.release(lease)
            }
            throw error
        }
    }

    private static func prepareDirectories(
        for location: TatwoCEFProfileLocation
    ) throws {
        let rootCacheURL = URL(
            fileURLWithPath: location.rootCachePath,
            isDirectory: true)
        let logFileURL = URL(
            fileURLWithPath: location.logFilePath,
            isDirectory: false)
        if let authorityPath = location.authorityStagingRootPath {
            let authorityURL = URL(
                fileURLWithPath: authorityPath,
                isDirectory: true)
            guard validatedAuthorityRoot(
                stagingRootURL: authorityURL,
                rootCacheURL: rootCacheURL) != nil,
                  logFileURL.deletingLastPathComponent()
                    .standardizedFileURL.path
                    == authorityURL.standardizedFileURL
                        .resolvingSymlinksInPath()
                        .appendingPathComponent(
                            "runtime",
                            isDirectory: true)
                        .appendingPathComponent(
                            "cef-logs",
                            isDirectory: true)
                        .path
            else {
                throw TatwoCEFProfileStoreError.pathEscapesRootCache
            }
        }
        for directory in [
            rootCacheURL,
            logFileURL.deletingLastPathComponent(),
        ] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true)
        }
        if let authorityPath = location.authorityStagingRootPath {
            let authorityURL = URL(
                fileURLWithPath: authorityPath,
                isDirectory: true)
            guard validatedAuthorityRoot(
                stagingRootURL: authorityURL,
                rootCacheURL: rootCacheURL) != nil
            else {
                throw TatwoCEFProfileStoreError.pathEscapesRootCache
            }
        }
        guard let identifier = location.persistentProfileIdentifier,
              let expectedProfilePath = location.persistentProfilePath
        else {
            return
        }
        let preparedURL = try TatwoCEFProfileStore(
            rootCacheURL: rootCacheURL)
            .prepareProfileParent(for: identifier)
        guard preparedURL.path == expectedProfilePath else {
            throw TatwoCEFProfileStoreError.preparedProfilePathMismatch(
                expected: expectedProfilePath,
                actual: preparedURL.path)
        }
    }

    private static func validatedAuthorityRoot(
        stagingRootURL: URL,
        rootCacheURL: URL,
        fileManager: FileManager = .default
    ) -> URL? {
        let stagingRoot = stagingRootURL
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let expected = stagingRoot
            .appendingPathComponent("runtime", isDirectory: true)
            .appendingPathComponent("cef-root", isDirectory: true)
            .standardizedFileURL
        guard rootCacheURL.standardizedFileURL.path == expected.path else {
            return nil
        }

        let runtimeRoot = stagingRoot
            .appendingPathComponent("runtime", isDirectory: true)
        for component in [
            runtimeRoot,
            runtimeRoot.appendingPathComponent(
                "cef-root",
                isDirectory: true),
            runtimeRoot.appendingPathComponent(
                "cef-logs",
                isDirectory: true),
        ] {
            if (try? fileManager.destinationOfSymbolicLink(
                atPath: component.path)) != nil
            {
                return nil
            }
            var isDirectory = ObjCBool(false)
            if fileManager.fileExists(
                atPath: component.path,
                isDirectory: &isDirectory),
               !isDirectory.boolValue
            {
                return nil
            }
        }

        guard let canonicalCandidate = TatwoCanonicalPath.resolvedURL(
            preservingMissingSuffixOf: expected,
            fileManager: fileManager),
              canonicalCandidate.path == expected.path,
              TatwoCEFProfileStore.isDescendant(
                canonicalCandidate,
                of: stagingRoot)
        else {
            return nil
        }
        return canonicalCandidate
    }
}

enum TatwoCEFGeometrySyncThrottlePolicy {
    static let minimumInterval: TimeInterval = 1.0 / 60.0

    static func delay(
        lastSyncUptime: TimeInterval,
        now: TimeInterval
    ) -> TimeInterval {
        max(0, minimumInterval - max(0, now - lastSyncUptime))
    }
}

@MainActor
enum TatwoCEFContainerTeardownContract {
    /// Remove the CEF-owned native child hierarchy from the host window
    /// immediately when its SwiftUI surface closes. The bridge remains alive
    /// in its closing registry until CEF's OnBeforeClose completion releases
    /// the profile lease, but it can no longer paint an orphan gray rectangle.
    static func detachFromHostWindow(_ browserView: NSView) {
        browserView.isHidden = true
        browserView.removeFromSuperview()
    }
}

@MainActor
final class TatwoCEFContainerView: NSView { // 2.0：開放給瀏覽器橋找到 CEF 視圖（原 private）
    private(set) var browserView: TatwoCEFBrowserView?
    private(set) var mountIdentity: EmbeddedChromiumBrowserMountIdentity?
    private var profileLease: TatwoCEFProfileLeaseRegistry.Lease?
    private var lastEmbeddingSignature: String?
    private var closeRequested = false
    private var closeCompleted = false
    private var closeCompletions: [() -> Void] = []
    private var isGeometryDragInProgress = false
    private var geometrySyncWorkItem: DispatchWorkItem?
    private var lastGeometrySyncUptime: TimeInterval = 0

    func install(
        _ browserView: TatwoCEFBrowserView,
        mountIdentity: EmbeddedChromiumBrowserMountIdentity,
        profileLease: TatwoCEFProfileLeaseRegistry.Lease?
    ) {
        self.browserView = browserView
        self.mountIdentity = mountIdentity
        self.profileLease = profileLease
        closeRequested = false
        closeCompleted = false
        wantsLayer = true
        browserView.wantsLayer = true
        logEmbeddingSnapshot(phase: "container_before_install", force: true)
        browserView.frame = bounds
        browserView.autoresizingMask = [.width, .height]
        addSubview(browserView)
        browserView.isHidden = false
        synchronizeBrowserGeometry(
            phase: "container_install",
            forceLog: true)
        logEmbeddingSnapshot(phase: "container_after_install", force: true)
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        logEmbeddingSnapshot(
            phase: "container_did_move_to_superview",
            force: true)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        logEmbeddingSnapshot(
            phase: "container_did_move_to_window",
            force: true)
    }

    override func layout() {
        super.layout()
        guard browserView != nil else {
            logEmbeddingSnapshot(phase: "container_layout_empty")
            return
        }
        if isGeometryDragInProgress {
            scheduleThrottledGeometrySync()
        } else {
            synchronizeBrowserGeometry(phase: "container_layout")
        }
    }

    func setGeometryDragInProgress(_ isInProgress: Bool) {
        guard isGeometryDragInProgress != isInProgress else {
            return
        }
        isGeometryDragInProgress = isInProgress
        guard !isInProgress else {
            scheduleThrottledGeometrySync()
            return
        }
        geometrySyncWorkItem?.cancel()
        geometrySyncWorkItem = nil
        synchronizeBrowserGeometry(
            phase: "container_drag_final",
            forceLog: true)
    }

    private func scheduleThrottledGeometrySync() {
        guard geometrySyncWorkItem == nil else {
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        let delay = TatwoCEFGeometrySyncThrottlePolicy.delay(
            lastSyncUptime: lastGeometrySyncUptime,
            now: now)
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.geometrySyncWorkItem = nil
            self.synchronizeBrowserGeometry(
                phase: "container_drag_frame")
        }
        geometrySyncWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + delay,
            execute: workItem)
    }

    private func synchronizeBrowserGeometry(
        phase: String,
        forceLog: Bool = false
    ) {
        guard let browserView else {
            return
        }
        lastGeometrySyncUptime =
            ProcessInfo.processInfo.systemUptime
        browserView.frame = bounds
        browserView.needsLayout = true
        logEmbeddingSnapshot(phase: phase, force: forceLog)
    }

    private func logEmbeddingSnapshot(
        phase: String,
        force: Bool = false
    ) {
        let browser = browserView
        let signature = [
            "frame=\(NSStringFromRect(frame))",
            "bounds=\(NSStringFromRect(bounds))",
            "hidden=\(isHidden)",
            "hiddenAncestor=\(isHiddenOrHasHiddenAncestor)",
            "wantsLayer=\(wantsLayer)",
            "layer=\(layer.map { String(describing: type(of: $0)) } ?? "none")",
            "window=\(window?.windowNumber ?? 0)",
            "windowVisible=\(window?.isVisible ?? false)",
            "browserClass=\(browser.map { String(describing: type(of: $0)) } ?? "none")",
            "browserFrame=\(browser.map { NSStringFromRect($0.frame) } ?? "none")",
            "browserHidden=\(browser?.isHidden ?? false)",
            "browserWantsLayer=\(browser?.wantsLayer ?? false)",
            "browserWindow=\(browser?.window?.windowNumber ?? 0)",
            "browserSuperviewMatches=\(browser?.superview === self)",
        ].joined(separator: " ")
        guard force || signature != lastEmbeddingSignature else {
            return
        }
        lastEmbeddingSignature = signature
        let ancestry = sequence(
            first: self as NSView?,
            next: { $0?.superview })
            .prefix(10)
            .compactMap { $0 }
            .map { String(describing: type(of: $0)) }
            .joined(separator: ">")
        let subviews = self.subviews
            .map { String(describing: type(of: $0)) }
            .joined(separator: ",")
        // Geometry-only diagnostics. Never log URL, profile paths, page text,
        // cookies, titles, or other session data.
        NSLog(
            "[TatwoCEF] embedding phase=%@ %@ ancestry=%@ subviews=%@",
            phase,
            signature,
            ancestry,
            subviews.isEmpty ? "none" : subviews)
    }

    func showUnavailable(message: String) {
        close()

        let label = NSTextField(labelWithString: message)
        label.alignment = .center
        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.maximumNumberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(
                greaterThanOrEqualTo: leadingAnchor,
                constant: 24),
            label.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor,
                constant: -24),
        ])
    }

    func close(completion: (() -> Void)? = nil) {
        if closeCompleted {
            completion?()
            return
        }
        if let completion { closeCompletions.append(completion) }
        guard !closeRequested else { return }
        closeRequested = true
        geometrySyncWorkItem?.cancel()
        geometrySyncWorkItem = nil
        let closingBrowser = browserView
        closingBrowser?.stateHandler = nil
        closingBrowser?.webMCPToolsHandler = nil
        let lease = profileLease
        profileLease = nil
        browserView = nil
        mountIdentity = nil
        guard let closingBrowser else {
            finishClose(lease: lease)
            return
        }
        TatwoCEFContainerTeardownContract.detachFromHostWindow(
            closingBrowser)
        closingBrowser.closeBrowser {
            Task { @MainActor in
                self.finishClose(lease: lease)
            }
        }
    }

    private func finishClose(lease: TatwoCEFProfileLeaseRegistry.Lease?) {
        if let lease {
            TatwoCEFProfileLeaseRegistry.shared.release(lease)
        }
        closeCompleted = true
        let completions = closeCompletions
        closeCompletions.removeAll()
        completions.forEach { $0() }
    }
}

struct EmbeddedChromiumBrowserMountIdentity: Hashable, Sendable {
    let profile: EmbeddedBrowserRuntimeProfile
    let profilePolicyTag: BrowserProfilePolicyTag

    var profileKey: UUID {
        profile.registryKey
    }

    init(
        profile: EmbeddedBrowserRuntimeProfile,
        profilePolicyTag: BrowserProfilePolicyTag? = nil
    ) {
        self.profile = profile
        self.profilePolicyTag = profilePolicyTag
            ?? (profile.dataStoreIdentifier == nil
                ? .humanEphemeral
                : .humanPersistent)
    }

    func mayShareRequestContext(
        with other: EmbeddedChromiumBrowserMountIdentity
    ) -> Bool {
        BrowserProfilePolicyTag.mayShareRequestContext(
            profilePolicyTag,
            other.profilePolicyTag)
            && profile == other.profile
    }
}

struct EmbeddedChromiumNavigationStateProjector {
    private var completedMainFrameURLString: String?

    mutating func project(
        committedMainFrameURLString: String?,
        navigationGeneration: UInt64,
        canGoBack: Bool,
        canGoForward: Bool,
        isLoading: Bool,
        phase: TatwoCEFBrowserPhase,
        httpStatusCode: Int,
        errorKind: TatwoCEFBrowserErrorKind,
        errorCode: Int,
        visibleError: String?
    ) -> EmbeddedBrowserNavigationState {
        let mappedPhase = EmbeddedBrowserLoadPhase(
            cefRawValue: phase.rawValue)
        let mappedErrorKind =
            EmbeddedBrowserNavigationErrorKind(
                cefRawValue: errorKind.rawValue)
        let committedURL = committedMainFrameURLString.flatMap {
            $0.isEmpty ? nil : $0
        }
        var projectedPhase = mappedPhase
        var projectedIsLoading = isLoading

        switch mappedPhase {
        case .committed:
            // A main-frame commit starts a new paint contract, including
            // same-URL reloads. Later browser-wide loading callbacks must not
            // inherit completion from the prior navigation.
            completedMainFrameURLString = nil
        case .finished:
            completedMainFrameURLString = committedURL
            projectedIsLoading = false
        case .loading
            where committedURL != nil
                && committedURL == completedMainFrameURLString:
            // CEF may toggle browser-wide loading for subresources after the
            // main frame has reached load-end/first-frame. Keep the completed
            // page visible instead of resurrecting the top loading chip.
            projectedPhase = .finished
            projectedIsLoading = false
        default:
            break
        }

        return EmbeddedBrowserNavigationState(
            urlString: committedURL,
            canGoBack: canGoBack,
            canGoForward: canGoForward,
            visibleError: visibleError.map {
                EmbeddedBrowserVisibleError.runtimeMessage($0)
            },
            isLoading: projectedIsLoading,
            phase: projectedPhase,
            committedMainFrameURLString: committedURL,
            navigationGeneration: navigationGeneration,
            httpStatusCode:
                httpStatusCode == 0 ? nil : httpStatusCode,
            structuredError: mappedErrorKind.flatMap { kind in
                visibleError.map {
                    EmbeddedBrowserNavigationError(
                        kind: kind,
                        code: errorCode == 0 ? nil : errorCode,
                        message: $0)
                }
            })
    }
}

/// Owns native tabs, not saved URLs. A profile has one lease and one secured
/// request context; each visited tab has its own browser, DOM and history.
@MainActor
final class TatwoCEFTabHostView: NSView {
    @MainActor
    private final class Entry {
        let container = TatwoCEFContainerView(frame: .zero)
        var projector = EmbeddedChromiumNavigationStateProjector()
        var state: EmbeddedBrowserNavigationState = .blank
    }

    let mountIdentity: EmbeddedChromiumBrowserMountIdentity
    var onNavigationStateChange: (String, EmbeddedBrowserNavigationState) -> Void
    private var entries: [String: Entry] = [:]
    private var profileLease: TatwoCEFProfileLeaseRegistry.Lease?
    private var closingCount = 0
    private var isClosing = false
    private var selectedTabID: String?
    private var selectedURL: URL?
    private var selectedAgentNavigation: BrowserAgentNavigation?
    private var openTabIDs: Set<String> = []
    private var failedTabIDs: Set<String> = []
    private var lastCommandID: UUID?
    private var pendingCommand: EmbeddedBrowserCommand?
    private var geometryDragInProgress = false

    init(
        mountIdentity: EmbeddedChromiumBrowserMountIdentity,
        onNavigationStateChange: @escaping (String, EmbeddedBrowserNavigationState) -> Void
    ) {
        self.mountIdentity = mountIdentity
        self.onNavigationStateChange = onNavigationStateChange
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { return nil }

    func update(
        tabID: String?, initialURL: URL?, initialAgentNavigation: BrowserAgentNavigation? = nil,
        openTabIDs: Set<String>,
        command: EmbeddedBrowserCommand?, isGeometryDragInProgress: Bool
    ) {
        guard !isClosing else { return }
        let selectionChanged = selectedTabID != tabID
        if selectionChanged { pendingCommand = nil }
        selectedTabID = tabID
        selectedURL = initialURL
        selectedAgentNavigation = initialAgentNavigation
        self.openTabIDs = openTabIDs
        geometryDragInProgress = isGeometryDragInProgress
        if let command, command.id != lastCommandID {
            lastCommandID = command.id
            pendingCommand = command
            if let tabID { failedTabIDs.remove(tabID) }
        }
        failedTabIDs.formIntersection(openTabIDs)
        for id in Array(entries.keys) where !openTabIDs.contains(id) {
            closeTab(id)
        }
        showSelectedTab()
        if selectionChanged, let tabID, let entry = entries[tabID] {
            publish(entry.state, tabID: tabID)
        }
        ensureSelectedTab()
    }

    private func showSelectedTab() {
        for (id, entry) in entries {
            let hidden = id != selectedTabID || selectedURL == nil
            if hidden, let responder = window?.firstResponder as? NSView,
               responder.isDescendant(of: entry.container) {
                window?.makeFirstResponder(nil)
            }
            // Real native visibility also scopes BrowserAgentBridge discovery.
            entry.container.isHidden = hidden
            entry.container.setGeometryDragInProgress(geometryDragInProgress)
        }
        if let selectedTabID, selectedURL != nil {
            TatwoWebMCPRuntime.shared.activate(tabID: selectedTabID)
        }
    }

    private func ensureSelectedTab() {
        guard !isClosing, let tabID = selectedTabID,
              openTabIDs.contains(tabID), let requestedURL = selectedURL,
              !failedTabIDs.contains(tabID) else { return }
        if let browser = entries[tabID]?.container.browserView {
            executePendingCommand(on: browser)
            return
        }
        // Do not race an old context's asynchronous native close with a new
        // root context at the same profile path.
        guard !entries.isEmpty || closingCount == 0 else { return }
        let source = entries.values.compactMap { $0.container.browserView }
            .first { $0.canShareRequestContext }
        if !entries.isEmpty && source == nil {
            // The first context's actual readiness callback resumes this work.
            // A failed source is not readiness and must not cause a retry loop.
            if entries.values.allSatisfy({ $0.state.visibleError != nil }) {
                fail(tabID, message: "瀏覽器未能就緒，請重新載入")
            }
            return
        }
        let initialURL: URL
        let initialNavigation: BrowserAgentNavigation?
        let initialCommandID = pendingCommand?.id
        if let pendingCommand, case let .load(url) = pendingCommand.action {
            initialURL = url
            initialNavigation = pendingCommand.agentNavigation
        } else {
            initialURL = requestedURL
            initialNavigation = selectedAgentNavigation
        }
        do {
            if let initialNavigation {
                guard initialNavigation.url.absoluteString == initialURL.absoluteString,
                      BrowserAgentBridge.shared.isRequestCurrent(initialNavigation.request) else {
                    throw BrowserAgentRequestError("browser_navigation_request_changed")
                }
            }
            // Agent URLs enter only the gate-aware load path below. Context
            // construction is host setup, not an input enqueue: keep it outside
            // the session lock and never give it an unguarded remote URL.
            let startupURL = initialNavigation == nil ? initialURL.absoluteString : "about:blank"
            let create: @MainActor () throws -> TatwoCEFBrowserView
            if let source {
                create = {
                    try TatwoCEFBrowserView(frame: .zero, sharingContextWith: source,
                                           initialURL: startupURL)
                }
            } else {
                guard let location = try TatwoCEFProfileLocationResolver.resolve(
                    profile: mountIdentity.profile),
                      location.profilePolicyTag == mountIdentity.profilePolicyTag
                else {
                    fail(tabID, message: "瀏覽器安裝或資料目錄無效，無法啟動")
                    return
                }
                profileLease = try TatwoCEFProfileLocationResolver.prepareForRuntime(location)
                try TatwoCEFRuntime.initialize(
                    withRootCachePath: location.rootCachePath,
                    helperExecutablePath: location.helperExecutablePath,
                    logFilePath: location.logFilePath,
                    bundledDenyListPath: BrowserBundledHostDenyList.verifiedResourceURL().path)
                // Profile I/O and runtime setup above must never hold the
                // Computer Use dispatch lock. Revalidate after they finish.
                create = {
                    try TatwoCEFBrowserView(frame: .zero, persistentProfile: location.persistentProfilePath,
                                           initialURL: startupURL)
                }
            }
            let browser = try create()
            if let initialNavigation {
                // Frame is still zero and unmounted, so this pairs URL + gate
                // before native startup. The gate reads the actual installed
                // container profile when it eventually dispatches.
                try BrowserAgentBridge.shared.enqueueCEFNavigation(
                    initialNavigation, on: browser,
                    profileID: mountIdentity.profile.dataStoreIdentifier)
            }
            let entry = Entry()
            entries[tabID] = entry
            browser.stateHandler = { [weak self, weak entry] (
                committedURL, generation, canGoBack, canGoForward,
                isLoading, phase, httpStatus, errorKind, errorCode, visibleError
            ) in
                guard let self, let entry, self.entries[tabID] === entry,
                      !self.isClosing else { return }
                entry.state = entry.projector.project(
                    committedMainFrameURLString: committedURL,
                    navigationGeneration: generation,
                    canGoBack: canGoBack, canGoForward: canGoForward,
                    isLoading: isLoading, phase: phase,
                    httpStatusCode: httpStatus, errorKind: errorKind,
                    errorCode: errorCode, visibleError: visibleError)
                self.publish(entry.state, tabID: tabID)
                // A native context-ready notification, not a timer or a fake
                // completion, opens a tab selected during context startup.
                self.ensureSelectedTab()
            }
            browser.webMCPToolsHandler = { snapshotJSON in
                TatwoWebMCPRuntime.shared.update(
                    tabID: tabID, snapshotJSONString: snapshotJSON)
            }
            TatwoWebMCPRuntime.shared.attach(tabID: tabID) {
                [weak browser] name, arguments, generation, completion in
                guard let browser else {
                    completion(nil, "webmcp_browser_unavailable")
                    return
                }
                browser.invokeWebMCPToolNamed(
                    name, argumentsJSON: arguments,
                    navigationGeneration: generation, completion: completion)
            }
            entry.container.frame = bounds
            entry.container.autoresizingMask = [.width, .height]
            // Consume before mounting: native startup can publish synchronously.
            if let pendingCommand, pendingCommand.id == initialCommandID,
               case .load = pendingCommand.action {
                self.pendingCommand = nil
            }
            entry.container.install(
                browser, mountIdentity: mountIdentity, profileLease: nil)
            addSubview(entry.container)
            showSelectedTab()
            executePendingCommand(on: browser)
        } catch {
            releaseLeaseIfIdle()
            fail(tabID, message: "瀏覽器建立失敗，請重新載入")
        }
    }

    private func executePendingCommand(on browser: TatwoCEFBrowserView) {
        guard let command = pendingCommand else { return }
        pendingCommand = nil
        let enqueue: @MainActor () -> Void
        switch command.action {
        case let .load(url): enqueue = { browser.loadURLString(url.absoluteString) }
        case .goBack: enqueue = { browser.goBack() }
        case .goForward: enqueue = { browser.goForward() }
        case .reload: enqueue = { browser.reload() }
        }
        do {
            if let navigation = command.agentNavigation {
                guard case let .load(url) = command.action else {
                    throw BrowserAgentRequestError("browser_navigation_action_changed")
                }
                guard navigation.url.absoluteString == url.absoluteString else {
                    throw BrowserAgentRequestError("browser_navigation_target_changed")
                }
                try BrowserAgentBridge.shared.enqueueCEFNavigation(
                    navigation, on: browser, profileID: mountIdentity.profile.dataStoreIdentifier)
            } else {
                enqueue()
            }
        } catch {
            if let selectedTabID {
                fail(selectedTabID, message: "瀏覽器操作已撤回，請重新觀察後再試。")
            }
        }
    }

    private func publish(_ state: EmbeddedBrowserNavigationState, tabID: String) {
        let entry = entries[tabID]
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isClosing, self.openTabIDs.contains(tabID),
                  self.entries[tabID] === entry else { return }
            self.onNavigationStateChange(tabID, state)
        }
    }

    private func fail(_ tabID: String, message: String) {
        failedTabIDs.insert(tabID)
        pendingCommand = nil
        publish(EmbeddedBrowserNavigationState(
            urlString: nil, canGoBack: false, canGoForward: false,
            visibleError: .runtimeMessage(message)), tabID: tabID)
    }

    private func closeTab(_ tabID: String) {
        guard let entry = entries.removeValue(forKey: tabID) else { return }
        TatwoWebMCPRuntime.shared.detach(tabID: tabID)
        closingCount += 1
        // The completion retains the host/lease until CEF OnBeforeClose, even
        // after SwiftUI has dismantled the host. There is no delayed release.
        entry.container.close { [self] in
            closingCount -= 1
            releaseLeaseIfIdle()
            if !isClosing { ensureSelectedTab() }
        }
        entry.container.removeFromSuperview()
    }

    private func releaseLeaseIfIdle() {
        guard entries.isEmpty, closingCount == 0 else { return }
        if let profileLease {
            TatwoCEFProfileLeaseRegistry.shared.release(profileLease)
            self.profileLease = nil
        }
    }

    func close() {
        guard !isClosing else { return }
        isClosing = true
        pendingCommand = nil
        for id in Array(entries.keys) { closeTab(id) }
        releaseLeaseIfIdle()
    }
}

struct EmbeddedChromiumBrowserView: NSViewRepresentable {
    let profile: EmbeddedBrowserRuntimeProfile
    let tabID: String?
    let initialURL: URL?
    var initialAgentNavigation: BrowserAgentNavigation? = nil
    let openTabIDs: Set<String>
    let command: EmbeddedBrowserCommand?
    let isGeometryDragInProgress: Bool
    let onNavigationStateChange: (String, EmbeddedBrowserNavigationState) -> Void

    func makeNSView(context: Context) -> TatwoCEFTabHostView {
        TatwoCEFTabHostView(
            mountIdentity: EmbeddedChromiumBrowserMountIdentity(profile: profile),
            onNavigationStateChange: onNavigationStateChange)
    }

    func updateNSView(_ host: TatwoCEFTabHostView, context: Context) {
        host.onNavigationStateChange = onNavigationStateChange
        host.update(
            tabID: tabID, initialURL: initialURL, initialAgentNavigation: initialAgentNavigation,
            openTabIDs: openTabIDs,
            command: command, isGeometryDragInProgress: isGeometryDragInProgress)
    }

    static func dismantleNSView(_ host: TatwoCEFTabHostView, coordinator: ()) {
        host.close()
    }
}

private extension EmbeddedBrowserLoadPhase {
    init(cefRawValue: Int) {
        switch cefRawValue {
        case 1: self = .creating
        case 2: self = .loading
        case 3: self = .committed
        case 4: self = .finished
        case 5: self = .blockedBySecurity
        case 6: self = .navigationFailed
        case 7: self = .rendererFailed
        case 8: self = .startupFailed
        case 9: self = .closed
        default: self = .blank
        }
    }
}

private extension EmbeddedBrowserNavigationErrorKind {
    init?(cefRawValue: Int) {
        switch cefRawValue {
        case 1: self = .security
        case 2: self = .navigation
        case 3: self = .renderer
        case 4: self = .startup
        default: return nil
        }
    }
}
