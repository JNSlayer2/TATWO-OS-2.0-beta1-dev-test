import Foundation

public enum TatwoSyncCatalogDocumentError: Error, Equatable, LocalizedError {
    case unsupportedSchemaVersion(Int)
    case emptyCatalogRevision
    case bundledCatalogUnavailable(String)
    case duplicatePersistentSurfaceID(String)
    case catalogInventoryMismatch(missing: [String], unknown: [String])
    case duplicateSystemPullDecision(String)
    case unknownSystemPullDecision(String)
    case invalidActiveSystemPullScope(String)
    case unclassifiedTransferableSurface([String])

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchemaVersion(let version):
            return "Unsupported sync catalog schema version: \(version)"
        case .emptyCatalogRevision:
            return "Sync catalog revision must not be empty"
        case .bundledCatalogUnavailable(let resource):
            return "Bundled sync catalog resource is unavailable: \(resource)"
        case .duplicatePersistentSurfaceID(let id):
            return "Duplicate persistent surface id: \(id)"
        case .catalogInventoryMismatch(let missing, let unknown):
            return "Sync catalog differs from durable surface inventory; missing=\(missing), unknown=\(unknown)"
        case .duplicateSystemPullDecision(let id):
            return "Sync catalog repeats a system-pull decision: \(id)"
        case .unknownSystemPullDecision(let id):
            return "Sync catalog system-pull decision references an unknown surface: \(id)"
        case .invalidActiveSystemPullScope(let id):
            return "Active system-pull surface must be shared: \(id)"
        case .unclassifiedTransferableSurface(let ids):
            return "Transferable surfaces lack an active/deferred system-pull decision: \(ids)"
        }
    }
}

public struct TatwoDurableSurfaceInventoryDocumentV1: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let inventoryRevision: String
    public let surfaceIDs: [String]

    public init(
        schemaVersion: Int = 1,
        inventoryRevision: String,
        surfaceIDs: [String]
    ) {
        self.schemaVersion = schemaVersion
        self.inventoryRevision = inventoryRevision
        self.surfaceIDs = surfaceIDs
    }

    public func validatedSurfaceIDs() throws -> Set<String> {
        guard schemaVersion == 1 else {
            throw TatwoSyncCatalogDocumentError.unsupportedSchemaVersion(schemaVersion)
        }
        guard !inventoryRevision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TatwoSyncCatalogDocumentError.emptyCatalogRevision
        }
        var result = Set<String>()
        for id in surfaceIDs {
            let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed == id, !trimmed.contains("/") else {
                throw TatwoSyncCatalogError.invalidID(id)
            }
            guard result.insert(id).inserted else {
                throw TatwoSyncCatalogDocumentError.duplicatePersistentSurfaceID(id)
            }
        }
        return result
    }
}

/// Versioned, file-backed declaration of every durable Work OS surface.
///
/// `persistentSurfaceIDs` is intentionally separate from `entries`: adding a
/// durable feature requires declaring the surface and assigning a sync policy.
/// Validation compares both sets and fails closed when a declaration has no
/// catalog entry.
public struct TatwoSyncCatalogDocumentV1: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let catalogRevision: String
    public let persistentSurfaceIDs: [String]
    public let systemPullItemIDs: [String]
    public let deferredSystemPullItemIDs: [String]
    public let entries: [TatwoSyncCatalogEntryV1]

    public init(
        schemaVersion: Int = 1,
        catalogRevision: String,
        persistentSurfaceIDs: [String],
        systemPullItemIDs: [String] = [],
        deferredSystemPullItemIDs: [String] = [],
        entries: [TatwoSyncCatalogEntryV1]
    ) {
        self.schemaVersion = schemaVersion
        self.catalogRevision = catalogRevision
        self.persistentSurfaceIDs = persistentSurfaceIDs
        self.systemPullItemIDs = systemPullItemIDs
        self.deferredSystemPullItemIDs = deferredSystemPullItemIDs
        self.entries = entries
    }

    public var catalog: TatwoSyncCatalogV1 {
        TatwoSyncCatalogV1(schemaVersion: schemaVersion, entries: entries)
    }

    public func validate() throws {
        guard schemaVersion == 1 else {
            throw TatwoSyncCatalogDocumentError.unsupportedSchemaVersion(schemaVersion)
        }
        guard !catalogRevision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TatwoSyncCatalogDocumentError.emptyCatalogRevision
        }

        var discovered = Set<String>()
        for id in persistentSurfaceIDs {
            let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed == id, !trimmed.contains("/") else {
                throw TatwoSyncCatalogError.invalidID(id)
            }
            guard discovered.insert(id).inserted else {
                throw TatwoSyncCatalogDocumentError.duplicatePersistentSurfaceID(id)
            }
        }
        try catalog.validatePersistentSurfaceIDs(discovered)

        let entriesByID = Dictionary(
            uniqueKeysWithValues: entries.map { ($0.id, $0) }
        )
        var decisions = Set<String>()
        for id in systemPullItemIDs + deferredSystemPullItemIDs {
            guard decisions.insert(id).inserted else {
                throw TatwoSyncCatalogDocumentError.duplicateSystemPullDecision(id)
            }
            guard entriesByID[id] != nil else {
                throw TatwoSyncCatalogDocumentError.unknownSystemPullDecision(id)
            }
        }
        for id in systemPullItemIDs {
            guard entriesByID[id]?.scope == .shared else {
                throw TatwoSyncCatalogDocumentError.invalidActiveSystemPullScope(id)
            }
        }
        let transferable = Set(
            entries.filter {
                $0.scope == .shared || $0.scope == .deviceOverlay
            }.map(\.id)
        )
        let unclassified = transferable.subtracting(decisions).sorted()
        guard unclassified.isEmpty else {
            throw TatwoSyncCatalogDocumentError.unclassifiedTransferableSurface(
                unclassified
            )
        }
    }

    public func validate(
        against inventory: TatwoDurableSurfaceInventoryDocumentV1
    ) throws {
        try validate()
        let inventoryIDs = try inventory.validatedSurfaceIDs()
        let declaredIDs = Set(persistentSurfaceIDs)
        let missing = inventoryIDs.subtracting(declaredIDs).sorted()
        let unknown = declaredIDs.subtracting(inventoryIDs).sorted()
        guard missing.isEmpty, unknown.isEmpty else {
            throw TatwoSyncCatalogDocumentError.catalogInventoryMismatch(
                missing: missing,
                unknown: unknown
            )
        }
        try catalog.validatePersistentSurfaceIDs(inventoryIDs)
    }

    public static func load(
        from url: URL,
        decoder: JSONDecoder = JSONDecoder()
    ) throws -> TatwoSyncCatalogDocumentV1 {
        let document = try decoder.decode(
            TatwoSyncCatalogDocumentV1.self,
            from: Data(contentsOf: url)
        )
        let inventoryURL = url.deletingLastPathComponent()
            .appendingPathComponent("tatwo-durable-surface-inventory-v1.json")
        let inventory = try decoder.decode(
            TatwoDurableSurfaceInventoryDocumentV1.self,
            from: Data(contentsOf: inventoryURL)
        )
        try document.validate(against: inventory)
        return document
    }

    /// Loads the catalog embedded in the shipping Core resource bundle.
    ///
    /// The App uses this copy as its fail-closed projection contract: a target
    /// receipt from another catalog revision cannot be shown as converged until
    /// the App itself ships that catalog revision.
    public static func loadBundled(
        decoder: JSONDecoder = JSONDecoder()
    ) throws -> TatwoSyncCatalogDocumentV1 {
        guard let catalogURL = Bundle.module.url(
            forResource: "tatwo-sync-catalog-v1",
            withExtension: "json"
        ) else {
            throw TatwoSyncCatalogDocumentError.bundledCatalogUnavailable(
                "tatwo-sync-catalog-v1.json"
            )
        }
        return try load(from: catalogURL, decoder: decoder)
    }
}
