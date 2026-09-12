import Foundation

public enum TatwoModuleIdentifierError: Error, Equatable, Sendable {
    case empty
    case invalidCharacter(String)
}

public struct TatwoModuleIDV1: Codable, Hashable, Sendable, RawRepresentable, Comparable {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw TatwoModuleIdentifierError.empty
        }

        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        guard trimmed.unicodeScalars.allSatisfy(allowed.contains) else {
            throw TatwoModuleIdentifierError.invalidCharacter(rawValue)
        }
        self.rawValue = trimmed
    }

    public init?(rawValue: String) {
        try? self.init(rawValue)
    }

    private enum CodingKeys: String, CodingKey {
        case rawValue
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(container.decode(String.self, forKey: .rawValue))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(rawValue, forKey: .rawValue)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct TatwoModuleVersionV1: Codable, Hashable, Sendable, Comparable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public let prerelease: String?

    public init(major: Int, minor: Int, patch: Int, prerelease: String? = nil) {
        precondition(major >= 0 && minor >= 0 && patch >= 0, "Version components must be non-negative")
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    public var description: String {
        let base = "\(major).\(minor).\(patch)"
        guard let prerelease, !prerelease.isEmpty else {
            return base
        }
        return "\(base)-\(prerelease)"
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil):
            return false
        case (nil, _?):
            return false
        case (_?, nil):
            return true
        case let (left?, right?):
            return left < right
        }
    }
}

public struct TatwoModuleDependencyV1: Codable, Hashable, Sendable {
    public let moduleID: TatwoModuleIDV1
    public let minimumVersion: TatwoModuleVersionV1?

    public init(moduleID: TatwoModuleIDV1, minimumVersion: TatwoModuleVersionV1? = nil) {
        self.moduleID = moduleID
        self.minimumVersion = minimumVersion
    }
}

public enum TatwoModuleLocationKindV1: String, Codable, Hashable, Sendable {
    case install
    case userData
    case cache
}

public struct TatwoModuleLocationDescriptorV1: Codable, Hashable, Sendable {
    public let kind: TatwoModuleLocationKindV1
    public let path: String

    public init(kind: TatwoModuleLocationKindV1, path: String) {
        self.kind = kind
        self.path = path
    }
}

public struct TatwoModuleLocationsV1: Codable, Hashable, Sendable {
    public let install: TatwoModuleLocationDescriptorV1
    public let data: TatwoModuleLocationDescriptorV1
    public let cache: TatwoModuleLocationDescriptorV1

    public init(
        install: TatwoModuleLocationDescriptorV1,
        data: TatwoModuleLocationDescriptorV1,
        cache: TatwoModuleLocationDescriptorV1
    ) {
        self.install = install
        self.data = data
        self.cache = cache
    }
}

public enum TatwoModuleHealthPolicyKindV1: String, Codable, Hashable, Sendable {
    case none
    case pathExists
    case executableProbe
    case customAdapter
}

public struct TatwoModuleHealthPolicyV1: Codable, Hashable, Sendable {
    public let kind: TatwoModuleHealthPolicyKindV1
    public let timeoutSeconds: Int
    public let successThreshold: Int

    public init(
        kind: TatwoModuleHealthPolicyKindV1,
        timeoutSeconds: Int = 5,
        successThreshold: Int = 1
    ) {
        precondition(timeoutSeconds >= 0, "Health timeout must be non-negative")
        precondition(successThreshold > 0, "Health success threshold must be positive")
        self.kind = kind
        self.timeoutSeconds = timeoutSeconds
        self.successThreshold = successThreshold
    }
}

public enum TatwoModuleMigrationModeV1: String, Codable, Hashable, Sendable {
    case none
    case explicitUserApproval
}

public struct TatwoModuleMigrationPolicyV1: Codable, Hashable, Sendable {
    public let mode: TatwoModuleMigrationModeV1
    public let currentSchemaVersion: Int

    public init(mode: TatwoModuleMigrationModeV1, currentSchemaVersion: Int) {
        precondition(currentSchemaVersion >= 0, "Schema version must be non-negative")
        self.mode = mode
        self.currentSchemaVersion = currentSchemaVersion
    }
}

public enum TatwoModuleRollbackScopeV1: String, Codable, Hashable, Sendable {
    case bundleOnly
}

public struct TatwoModuleRollbackPolicyV1: Codable, Hashable, Sendable {
    public let scope: TatwoModuleRollbackScopeV1
    public let retainedVerifiedArchives: Int

    public init(scope: TatwoModuleRollbackScopeV1 = .bundleOnly, retainedVerifiedArchives: Int) {
        precondition(retainedVerifiedArchives >= 1, "At least one verified archive is required")
        self.scope = scope
        self.retainedVerifiedArchives = retainedVerifiedArchives
    }
}

public enum TatwoResettableArtifactV1: String, Codable, Hashable, Sendable, CaseIterable {
    case cache
    case stagedBundle
    case generatedState
}

public struct TatwoModuleResetPolicyV1: Codable, Hashable, Sendable {
    public let resettableArtifacts: [TatwoResettableArtifactV1]
    public let preservesUserData: Bool
    public let preservesDomainLedger: Bool

    public init(resettableArtifacts: [TatwoResettableArtifactV1]) {
        var seen = Set<TatwoResettableArtifactV1>()
        self.resettableArtifacts = resettableArtifacts.filter { seen.insert($0).inserted }
        self.preservesUserData = true
        self.preservesDomainLedger = true
    }

    private enum CodingKeys: String, CodingKey {
        case resettableArtifacts
        case preservesUserData
        case preservesDomainLedger
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let preservesUserData = try container.decode(Bool.self, forKey: .preservesUserData)
        let preservesDomainLedger = try container.decode(Bool.self, forKey: .preservesDomainLedger)
        guard preservesUserData, preservesDomainLedger else {
            throw DecodingError.dataCorruptedError(
                forKey: preservesUserData ? .preservesDomainLedger : .preservesUserData,
                in: container,
                debugDescription: "Module reset must preserve user data and the domain ledger"
            )
        }
        self.init(
            resettableArtifacts: try container.decode(
                [TatwoResettableArtifactV1].self,
                forKey: .resettableArtifacts
            )
        )
    }
}

public enum TatwoModuleManifestValidationError: Error, Equatable, Sendable {
    case duplicateDependency(TatwoModuleIDV1)
    case selfDependency(TatwoModuleIDV1)
    case invalidLocationKind(expected: TatwoModuleLocationKindV1, actual: TatwoModuleLocationKindV1)
}

public struct TatwoModuleManifestV1: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let moduleID: TatwoModuleIDV1
    public let version: TatwoModuleVersionV1
    public let dependencies: [TatwoModuleDependencyV1]
    public let locations: TatwoModuleLocationsV1
    public let health: TatwoModuleHealthPolicyV1
    public let migration: TatwoModuleMigrationPolicyV1
    public let rollback: TatwoModuleRollbackPolicyV1
    public let reset: TatwoModuleResetPolicyV1

    public init(
        moduleID: TatwoModuleIDV1,
        version: TatwoModuleVersionV1,
        dependencies: [TatwoModuleDependencyV1],
        locations: TatwoModuleLocationsV1,
        health: TatwoModuleHealthPolicyV1,
        migration: TatwoModuleMigrationPolicyV1,
        rollback: TatwoModuleRollbackPolicyV1,
        reset: TatwoModuleResetPolicyV1
    ) throws {
        var seen = Set<TatwoModuleIDV1>()
        for dependency in dependencies {
            guard dependency.moduleID != moduleID else {
                throw TatwoModuleManifestValidationError.selfDependency(moduleID)
            }
            guard seen.insert(dependency.moduleID).inserted else {
                throw TatwoModuleManifestValidationError.duplicateDependency(dependency.moduleID)
            }
        }

        guard locations.install.kind == .install else {
            throw TatwoModuleManifestValidationError.invalidLocationKind(
                expected: .install,
                actual: locations.install.kind
            )
        }
        guard locations.data.kind == .userData else {
            throw TatwoModuleManifestValidationError.invalidLocationKind(
                expected: .userData,
                actual: locations.data.kind
            )
        }
        guard locations.cache.kind == .cache else {
            throw TatwoModuleManifestValidationError.invalidLocationKind(
                expected: .cache,
                actual: locations.cache.kind
            )
        }

        self.schemaVersion = 1
        self.moduleID = moduleID
        self.version = version
        self.dependencies = dependencies
        self.locations = locations
        self.health = health
        self.migration = migration
        self.rollback = rollback
        self.reset = reset
    }
}

public enum TatwoModuleHealthStatusV1: String, Codable, Hashable, Sendable {
    case unknown
    case healthy
    case degraded
    case unhealthy
}

public struct TatwoModuleHealthSnapshotV1: Codable, Hashable, Sendable {
    public let moduleID: TatwoModuleIDV1
    public let version: TatwoModuleVersionV1
    public let status: TatwoModuleHealthStatusV1
    public let observedAt: Date
    public let detail: String

    public init(
        moduleID: TatwoModuleIDV1,
        version: TatwoModuleVersionV1,
        status: TatwoModuleHealthStatusV1,
        observedAt: Date,
        detail: String
    ) {
        self.moduleID = moduleID
        self.version = version
        self.status = status
        self.observedAt = observedAt
        self.detail = detail
    }
}

public protocol TatwoModuleHealthSnapshotProvider {
    func moduleHealthSnapshots() -> [TatwoModuleHealthSnapshotV1]
}
