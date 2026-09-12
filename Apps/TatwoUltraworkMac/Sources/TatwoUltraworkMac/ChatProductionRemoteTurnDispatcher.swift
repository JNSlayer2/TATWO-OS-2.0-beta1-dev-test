import CryptoKit
import Foundation
import Security
import TatwoDomainContracts
import TatwoUltraworkCore

enum TatwoChatProcessClass: Sendable, Equatable {
    case production
    case localInternal
    case isolated
}

enum TatwoProductionCodeSignatureTrust: Sendable, Equatable {
    case trusted
    case currentAdHoc
    case rejected
    case unknown
}

enum TatwoLocalInternalInstallTrust: Sendable, Equatable {
    case trusted
    case rejected
    case unknown
}

enum TatwoProductionPromotionTrust: Sendable, Equatable {
    case trusted
    case rejected
    case unknown
}

struct TatwoChatProcessStorageLayout {
    let applicationSupportRootURL: URL
    let stateRootURL: URL
    let nativeChatStoreURL: URL
    let preferenceStoreURL: URL
    let pluginRegistryStoreURL: URL
    let scenarioConfigStoreURL: URL
    let chatRuntimeRootURL: URL
    let cancellationStateStoreURL: URL
    let transcriptJournalStoreURL: URL
    let pendingRemoteTargetStoreURL: URL
    let environment: [String: String]

    init(
        processClass: TatwoChatProcessClass,
        applicationSupportRootURL: URL,
        stateRootURL: URL,
        environment: [String: String]
    ) {
        let appSupport = applicationSupportRootURL.standardizedFileURL
        let state = stateRootURL.standardizedFileURL
        self.applicationSupportRootURL = appSupport
        self.stateRootURL = state
        nativeChatStoreURL = appSupport.appendingPathComponent(
            "native-chat-threads.json",
            isDirectory: false)
        preferenceStoreURL = state.appendingPathComponent(
            "preferences.json",
            isDirectory: false)
        pluginRegistryStoreURL = appSupport.appendingPathComponent(
            "plugin-registry.json",
            isDirectory: false)
        scenarioConfigStoreURL = appSupport.appendingPathComponent(
            "scenario-config.json",
            isDirectory: false)
        chatRuntimeRootURL = state.appendingPathComponent(
            "chat-cli-runtime-v1",
            isDirectory: true)
        cancellationStateStoreURL = state.appendingPathComponent(
            "chat-cancellation-lock-v1.json",
            isDirectory: false)
        transcriptJournalStoreURL = appSupport.appendingPathComponent(
            "chat-transcript-journal-v1.json",
            isDirectory: false)
        pendingRemoteTargetStoreURL = appSupport.appendingPathComponent(
            "pending-remote-target-v1.json",
            isDirectory: false)

        var isolatedEnvironment = environment
        isolatedEnvironment[
            TatwoProductionLayoutLock.appSupportEnvKey
        ] = appSupport.path
        isolatedEnvironment[
            TatwoProductionLayoutLock.stateDirEnvKey
        ] = state.path
        isolatedEnvironment[
            "TATWO_ULTRAWORK_NATIVE_CHAT_STORE"
        ] = nativeChatStoreURL.path
        isolatedEnvironment[
            "TATWO_ULTRAWORK_PREFERENCES"
        ] = preferenceStoreURL.path
        isolatedEnvironment[
            "TATWO_ULTRAWORK_PLUGIN_REGISTRY_PATH"
        ] = pluginRegistryStoreURL.path
        isolatedEnvironment[
            "TATWO_ULTRAWORK_SCENARIO_CONFIG_PATH"
        ] = scenarioConfigStoreURL.path
        if processClass == .isolated {
            // Finder/open launches have no TATWO_* layout variables. Publish
            // the composition's isolated roots explicitly and keep staging
            // from mirroring production Codex/session data by default.
            isolatedEnvironment[
                "TATWO_ULTRAWORK_CHAT_CODEX_MIRROR"
            ] = "0"
            isolatedEnvironment[
                "TATWO_ULTRAWORK_CHAT_CODEX_PROJECT_SYNC"
            ] = "0"
            isolatedEnvironment[
                "TATWO_ULTRAWORK_PLG_ANCHOR_SERVICE"
            ] = "ai.tatwo.ultrawork.plg-chain-anchor.isolated"
            isolatedEnvironment[
                "TATWO_ULTRAWORK_PLG_ANCHOR_ACCOUNT"
            ] = state.path
        }
        self.environment = isolatedEnvironment
    }
}

/// Process-lifetime Chat wiring chosen from packaged bundle identity rather
/// than mutable layout environment.
///
/// Production authority requires the canonical non-symlink installation path,
/// production-only build markers, no staging marker, and no XCTest bundle.
/// Formal production additionally requires the production marker tuple and
/// trusted Developer ID identity. A verified local-internal install may reuse
/// the OS-native user-data layout, but receives separate runner/authorization
/// roots and the unavailable dispatcher. Staging/test processes use isolated
/// state. Neither non-production class can call
/// `TatwoLoopProductionRunnerBootstrap.dispatch`.
struct TatwoChatProcessComposition {
    let processClass: TatwoChatProcessClass
    let storage: TatwoChatProcessStorageLayout
    let stateRootURL: URL
    let nativeChatStore: TatwoNativeChatStore
    let preferenceStore: TatwoPreferenceStore
    let pluginRegistryStore: TatwoPluginRegistryStore
    let goalRunStore: TatwoGoalRunStore
    let dispatchRegistry: TatwoDispatchRegistry
    let plgChainStore: TatwoPLGChainStore
    let pendingRemoteTargetStore: ChatPendingRemoteTargetDiskStore
    let cancellationStateStore: ChatCancellationStateDiskStore
    let runnerAuthority: ChatDurableRunnerAuthority
    let remoteBorrowAuthorizationStore: TatwoRemoteBorrowAuthorizationStore
    let remoteTurnDispatcher: any ChatRemoteTurnDispatching

    @MainActor
    func makeChatPageModel(
        appMCPRuntimeProvider:
            @escaping @MainActor () -> TatwoAppMCPRuntimeState = {
                .notStarted
            }
    ) -> ChatPageModel {
        ChatPageModel(
            environment: storage.environment,
            store: nativeChatStore,
            transcriptJournalStore: ChatTranscriptJournalDiskStore(
                fileURL: storage.transcriptJournalStoreURL),
            processStorageLayout: storage,
            goalRunStore: goalRunStore,
            plgChainStore: plgChainStore,
            dispatchRegistry: dispatchRegistry,
            preferenceStore: preferenceStore,
            pluginRegistryStore: pluginRegistryStore,
            gatewayCooldownStore: TatwoGatewayCooldownStore(
                directoryURL: goalRunStore.directoryURL),
            remoteBorrowAuthorizationStore:
                remoteBorrowAuthorizationStore,
            pendingRemoteTargetStore: pendingRemoteTargetStore,
            remoteTurnDispatcher: remoteTurnDispatcher,
            runnerAuthorityDiscoverer: runnerAuthority,
            cancellationStateStore: cancellationStateStore,
            chatRuntimeRootURL: storage.chatRuntimeRootURL,
            appMCPRuntimeProvider: appMCPRuntimeProvider)
    }
}

enum TatwoChatProcessCompositionResolver {
    private enum BuildAuthorityProfile {
        case formalProduction
        case localInternal
    }

    private struct BundleContentManifest: Decodable {
        struct MainExecutable: Decodable {
            let path: String
            let sha256: String
            let digestMode: String
        }

        struct Entry: Decodable {
            let path: String
            let type: String
            let mode: String
            let sha256: String
            let size: UInt64
            let digestMode: String
        }

        let schema: String
        let exclusions: [String]
        let mainExecutable: MainExecutable
        let entries: [Entry]
    }

    private struct EmbeddedCandidateProvenance: Decodable {
        let schema: String
        let candidateID: String
        let sourceCommit: String
        let sourceTree: String
        let sourceDirty: Bool
        let sourceSnapshotSHA256: String
        let sourceTreeManifestSHA256: String
        let buildInputManifestSHA256: String
        let buildOutputManifestSHA256: String
        let bundleContentManifestSHA256: String
        let mainExecutableSHA256: String
        let provenanceNodeSHA256: String
        let provenanceNodeCDHash: String
        let provenanceNodeVersion: String
    }

    private struct LocalDeviceIdentity: Decodable {
        let deviceId: String
    }

    private struct SignedReleaseManifest: Decodable {
        struct Artifact: Decodable {
            let sha256: String
            let bytes: UInt64
            let sparkleEdDSASignature: String
        }

        struct BundleIdentity: Decodable {
            let identifier: String
            let executable: String
            let cdhash: String
            let helperSHA256: String
        }

        struct UpdateEvidence: Decodable {
            let appcastSHA256: String
        }

        struct Provenance: Decodable {
            let sourceCommit: String
            let sourceTree: String
            let developerIDTeamID: String
            let notarizationStatus: String
            let notarizationSubmissionID: String
        }

        let schema: String
        let version: String
        let build: String
        let channel: String
        let feedURL: String
        let artifact: Artifact
        let bundle: BundleIdentity
        let updateEvidence: UpdateEvidence
        let provenance: Provenance
    }

    struct BundleContentDigestResult: Sendable, Equatable {
        let sha256: String
        let size: UInt64
    }

    typealias ProductionSignatureTrustProvider =
        (URL) -> TatwoProductionCodeSignatureTrust
    typealias LocalInternalInstallTrustProvider =
        (
            URL,
            [String: Any],
            URL?,
            FileManager,
            TatwoProductionCodeSignatureTrust
        ) -> TatwoLocalInternalInstallTrust
    typealias ProductionPromotionTrustProvider =
        (
            URL,
            [String: Any],
            URL?,
            FileManager
        ) -> TatwoProductionPromotionTrust
    typealias ProductionBundleCDHashProvider = (URL) -> String?
    typealias ProductionRunnerAuthorityFactory =
        (URL) -> ChatDurableRunnerAuthority
    typealias ProductionAuthorizationStoreFactory =
        (URL) -> TatwoRemoteBorrowAuthorizationStore
    typealias BundleContentDigestProvider =
        (
            _ fileURL: URL,
            _ digestMode: String,
            _ fileManager: FileManager
        ) -> BundleContentDigestResult?

    static let canonicalProductionBundleURL = URL(
        fileURLWithPath: "/Applications/Tatwo Ultrawork.app",
        isDirectory: true)
    static let expectedProductionTeamIdentifier = "W47594XKQC"
    static let productionPromotionDirectoryName =
        "production-release-promotion-v1"
    static let productionPromotionManifestName =
        "release-manifest.json"
    static let productionPromotionSignatureName =
        "release-manifest.ed25519"
    static let productionDesignatedRequirement =
        """
        anchor apple generic \
        and certificate leaf[field.1.2.840.113635.100.6.1.13] exists \
        and certificate 1[field.1.2.840.113635.100.6.2.6] exists \
        and certificate leaf[subject.OU] = \
        "\(expectedProductionTeamIdentifier)" \
        and identifier "\(TatwoRuntimeLayout.bundleIdentifier)"
        """
    static let stagingMarkerInfoKey = "TatwoStagingAnchorIdentity"
    static let productionHelperDigestInfoKey =
        "TatwoPLGAnchorHelperSHA256"
    static let bundleContentManifestDigestInfoKey =
        "TatwoBundleContentManifestSHA256"
    static let mainExecutableDigestInfoKey =
        "TatwoMainExecutableSHA256"
    static let bundleContentManifestRelativePath =
        "Contents/Resources/TatwoBundleContentManifestV1.json"
    private static let bundleContentManifestExclusions = [
        "Contents/Info.plist",
        "Contents/_CodeSignature/**",
        bundleContentManifestRelativePath,
        "Contents/Resources/TatwoCandidateProvenance.json",
    ]
    private static let localInternalInstallReceiptAuthorityKeys: Set<String> = [
        "schema",
        "receipt_id",
        "receipt_nonce",
        "receipt_filename",
        "signing",
        "signing_mode",
        "signing_identity",
        "force_adhoc",
        "dry_run",
        "app_bundle",
        "app_version",
        "app_build",
        "source_commit",
        "source_tree",
        "source_dirty",
        "candidate_id",
        "source_snapshot_sha256",
        "source_tree_manifest_sha256",
        "build_input_manifest_sha256",
        "build_output_manifest_sha256",
        "bundle_content_manifest_sha256",
        "main_executable_sha256",
        "embedded_provenance_sha256",
        "provenance_node_sha256",
        "provenance_node_cdhash",
        "provenance_node_version",
        "stage_only",
        "distribution",
        "generated_at",
    ]
    private static let localInternalInstallReceiptV2ForensicKeys:
        Set<String> = [
            "staged_bundle_manifest_sha256",
            "staged_bundle_identity_sha256",
        ]
    private static let localInternalInstallReceiptV3ForensicKeys:
        Set<String> = [
            "forensic_staged_bundle_manifest_sha256",
            "forensic_staged_bundle_identity_sha256",
        ]
    static let sourceCommitInfoKey = "TatwoSourceCommit"
    static let sourceTreeInfoKey = "TatwoSourceTree"
    static let candidateIDInfoKey = "TatwoCandidateID"
    static let sourceDirtyInfoKey = "TatwoSourceDirty"
    static let sourceSnapshotDigestInfoKey =
        "TatwoSourceSnapshotSHA256"
    static let sourceTreeManifestDigestInfoKey =
        "TatwoSourceTreeManifestSHA256"
    static let buildInputManifestDigestInfoKey =
        "TatwoBuildInputManifestSHA256"
    static let buildOutputManifestDigestInfoKey =
        "TatwoBuildOutputManifestSHA256"
    static let embeddedProvenanceDigestInfoKey =
        "TatwoEmbeddedProvenanceSHA256"
    static let provenanceNodeDigestInfoKey =
        "TatwoProvenanceNodeSHA256"
    static let provenanceNodeCDHashInfoKey =
        "TatwoProvenanceNodeCDHash"
    static let provenanceNodeVersionInfoKey =
        "TatwoProvenanceNodeVersion"
    static let buildClassInfoKey = "TatwoBuildClass"
    static let distributionReadyInfoKey = "TatwoDistributionReady"
    static let automaticUpdatesInfoKey = "TatwoAutomaticUpdatesEnabled"
    static let formalProductionBuildClass = "production-intent"
    static let localInternalBuildClass = "local-internal"
    // Security.framework exposes the ad-hoc signature flag in the C headers,
    // but this SDK does not import kSecCodeSignatureAdhoc into Swift.
    private static let adHocCodeSignatureFlag: UInt32 = 0x0002

    static func processClass(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary,
        bundleURL: URL = Bundle.main.bundleURL,
        expectedProductionBundleURL: URL = canonicalProductionBundleURL,
        productionSignatureTrustProvider:
            ProductionSignatureTrustProvider =
                systemProductionSignatureTrust,
        productionPromotionTrustProvider:
            ProductionPromotionTrustProvider =
                systemProductionPromotionTrust,
        localInternalInstallTrustProvider:
            LocalInternalInstallTrustProvider =
                systemLocalInternalInstallTrust,
        applicationSupportBase: URL? = nil,
        fileManager: FileManager = .default
    ) -> TatwoChatProcessClass {
        let stagingMarker = nonempty(
            infoDictionary?[stagingMarkerInfoKey] as? String)
        let sourceCommit =
            infoDictionary?[sourceCommitInfoKey] as? String
        let sourceTree =
            infoDictionary?[sourceTreeInfoKey] as? String
        let helperDigest =
            infoDictionary?[productionHelperDigestInfoKey] as? String
        let buildAuthorityProfile = buildAuthorityProfile(
            infoDictionary)
        let executableName = nonempty(
            infoDictionary?["CFBundleExecutable"] as? String)
        let isTestBundle =
            bundleURL.pathExtension.lowercased() == "xctest"
            || bundleIdentifier?.lowercased().contains("xctest") == true
            || bundleIdentifier?.lowercased().hasSuffix(".tests") == true
        guard bundleIdentifier == TatwoRuntimeLayout.bundleIdentifier,
              stagingMarker == nil,
              executableName == "TatwoUltraworkMac",
              isLowercaseHex(sourceCommit, count: 40),
              isLowercaseHex(sourceTree, count: 40),
              isLowercaseHex(helperDigest, count: 64),
              let buildAuthorityProfile,
              isExactCanonicalProductionBundle(
                bundleURL,
                expected: expectedProductionBundleURL),
              !isTestBundle
        else {
            return .isolated
        }

        let signatureTrust =
            productionSignatureTrustProvider(bundleURL)
        switch buildAuthorityProfile {
        case .formalProduction:
            // A Developer ID signature proves who signed the bundle, not that
            // this build passed notarization and signed-appcast release gates.
            // The in-bundle marker is intentionally only production intent;
            // exact externally signed promotion evidence must elevate it.
            guard signatureTrust == .trusted,
                  productionPromotionTrustProvider(
                    bundleURL,
                    infoDictionary ?? [:],
                    applicationSupportBase,
                    fileManager
                  ) == .trusted
            else {
                return .isolated
            }
            return .production
        case .localInternal:
            // The canonical local-internal App is intentionally allowed to
            // own the installed user's state, but never from signature/path
            // alone. Both its marker tuple and the sealed install evidence
            // must agree, whether the installer used ad-hoc or Developer ID.
            guard signatureTrust == .trusted
                    || signatureTrust == .currentAdHoc,
                  localInternalInstallTrustProvider(
                    bundleURL,
                    infoDictionary ?? [:],
                    applicationSupportBase,
                    fileManager,
                    signatureTrust
                  ) == .trusted
            else {
                return .isolated
            }
            return .localInternal
        }
    }

    private static func buildAuthorityProfile(
        _ infoDictionary: [String: Any]?
    ) -> BuildAuthorityProfile? {
        guard let buildClass =
                infoDictionary?[buildClassInfoKey] as? String,
              let distributionReady = strictBooleanMarker(
                infoDictionary?[distributionReadyInfoKey]),
              let automaticUpdatesEnabled = strictBooleanMarker(
                infoDictionary?[automaticUpdatesInfoKey])
        else {
            return nil
        }

        switch (
            buildClass,
            distributionReady,
            automaticUpdatesEnabled
        ) {
        case (formalProductionBuildClass, false, false):
            return .formalProduction
        case (localInternalBuildClass, false, false):
            return .localInternal
        default:
            // Mixed marker tuples are not partial authority. Examples include
            // a local build claiming distribution readiness or a production-
            // intent build claiming it has already completed promotion.
            return nil
        }
    }

    static func stateRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary,
        bundleURL: URL = Bundle.main.bundleURL,
        expectedProductionBundleURL: URL = canonicalProductionBundleURL,
        productionSignatureTrustProvider:
            ProductionSignatureTrustProvider =
                systemProductionSignatureTrust,
        productionPromotionTrustProvider:
            ProductionPromotionTrustProvider =
                systemProductionPromotionTrust,
        localInternalInstallTrustProvider:
            LocalInternalInstallTrustProvider =
                systemLocalInternalInstallTrust,
        applicationSupportBase: URL? = nil,
        fileManager: FileManager = .default,
        processID: Int32 = ProcessInfo.processInfo.processIdentifier
    ) -> URL {
        let resolvedClass = processClass(
            bundleIdentifier: bundleIdentifier,
            infoDictionary: infoDictionary,
            bundleURL: bundleURL,
            expectedProductionBundleURL:
                expectedProductionBundleURL,
            productionSignatureTrustProvider:
                productionSignatureTrustProvider,
            productionPromotionTrustProvider:
                productionPromotionTrustProvider,
            localInternalInstallTrustProvider:
                localInternalInstallTrustProvider,
            applicationSupportBase: applicationSupportBase,
            fileManager: fileManager)
        return stateRoot(
            for: resolvedClass,
            environment: environment,
            bundleIdentifier: bundleIdentifier,
            bundleURL: bundleURL,
            applicationSupportBase: applicationSupportBase,
            fileManager: fileManager,
            processID: processID)
    }

    static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary,
        bundleURL: URL = Bundle.main.bundleURL,
        expectedProductionBundleURL: URL = canonicalProductionBundleURL,
        productionSignatureTrustProvider:
            ProductionSignatureTrustProvider =
                systemProductionSignatureTrust,
        productionPromotionTrustProvider:
            ProductionPromotionTrustProvider =
                systemProductionPromotionTrust,
        localInternalInstallTrustProvider:
            LocalInternalInstallTrustProvider =
                systemLocalInternalInstallTrust,
        applicationSupportBase: URL? = nil,
        fileManager: FileManager = .default,
        processID: Int32 = ProcessInfo.processInfo.processIdentifier,
        productionRunnerAuthorityFactory:
            ProductionRunnerAuthorityFactory = {
                ChatDurableRunnerAuthority.production(stateRoot: $0)
            },
        productionAuthorizationStoreFactory:
            ProductionAuthorizationStoreFactory = {
                TatwoRemoteBorrowAuthorizationStore.production(stateRoot: $0)
            },
        productionRemoteDispatcherFactory:
            () -> any ChatRemoteTurnDispatching = {
                ChatProductionRemoteTurnDispatcher.production()
            }
    ) -> TatwoChatProcessComposition {
        // Decide the trust class before constructing any production service.
        let resolvedClass = processClass(
            bundleIdentifier: bundleIdentifier,
            infoDictionary: infoDictionary,
            bundleURL: bundleURL,
            expectedProductionBundleURL:
                expectedProductionBundleURL,
            productionSignatureTrustProvider:
                productionSignatureTrustProvider,
            productionPromotionTrustProvider:
                productionPromotionTrustProvider,
            localInternalInstallTrustProvider:
                localInternalInstallTrustProvider,
            applicationSupportBase: applicationSupportBase,
            fileManager: fileManager)
        let resolvedStateRoot = stateRoot(
            for: resolvedClass,
            environment: environment,
            bundleIdentifier: bundleIdentifier,
            bundleURL: bundleURL,
            applicationSupportBase: applicationSupportBase,
            fileManager: fileManager,
            processID: processID)

        let productionAppSupport =
            TatwoProductionLayoutLock.osNativeApplicationSupportRoot(
                applicationSupportBase: applicationSupportBase,
                fileManager: fileManager)
        let isolatedAppSupport = resolvedStateRoot.appendingPathComponent(
            "chat-app-support-v1",
            isDirectory: true)
        let storage = TatwoChatProcessStorageLayout(
            processClass: resolvedClass,
            applicationSupportRootURL:
                resolvedClass == .isolated
                ? isolatedAppSupport
                : productionAppSupport,
            stateRootURL: resolvedStateRoot,
            environment: environment)
        let nativeChatStore = TatwoNativeChatStore.defaultStore(
            environment: storage.environment,
            fileManager: fileManager)
        let preferenceStore = TatwoPreferenceStore(
            fileURL: storage.preferenceStoreURL)
        let pluginRegistryStore = TatwoPluginRegistryStore(
            fileURL: storage.pluginRegistryStoreURL)
        let goalRunStore = TatwoGoalRunStore(
            directoryURL: storage.stateRootURL)
        let dispatchRegistry = TatwoDispatchRegistry(
            directoryURL: goalRunStore.directoryURL)
        let plgChainStore = TatwoPLGChainStore.defaultStore(
            environment: storage.environment,
            baseDirectory: storage.applicationSupportRootURL)
        let pendingRemoteTargetStore =
            ChatPendingRemoteTargetDiskStore(
                fileURL: storage.pendingRemoteTargetStoreURL)
        let cancellationStateStore = ChatCancellationStateDiskStore(
            fileURL: storage.cancellationStateStoreURL)

        switch resolvedClass {
        case .production:
            return TatwoChatProcessComposition(
                processClass: .production,
                storage: storage,
                stateRootURL: resolvedStateRoot,
                nativeChatStore: nativeChatStore,
                preferenceStore: preferenceStore,
                pluginRegistryStore: pluginRegistryStore,
                goalRunStore: goalRunStore,
                dispatchRegistry: dispatchRegistry,
                plgChainStore: plgChainStore,
                pendingRemoteTargetStore: pendingRemoteTargetStore,
                cancellationStateStore: cancellationStateStore,
                runnerAuthority:
                    productionRunnerAuthorityFactory(resolvedStateRoot),
                remoteBorrowAuthorizationStore:
                    productionAuthorizationStoreFactory(resolvedStateRoot),
                remoteTurnDispatcher:
                    productionRemoteDispatcherFactory())
        case .localInternal:
            return TatwoChatProcessComposition(
                processClass: .localInternal,
                storage: storage,
                stateRootURL: resolvedStateRoot,
                nativeChatStore: nativeChatStore,
                preferenceStore: preferenceStore,
                pluginRegistryStore: pluginRegistryStore,
                goalRunStore: goalRunStore,
                dispatchRegistry: dispatchRegistry,
                plgChainStore: plgChainStore,
                pendingRemoteTargetStore: pendingRemoteTargetStore,
                cancellationStateStore: cancellationStateStore,
                runnerAuthority: ChatDurableRunnerAuthority(
                    rootURL: resolvedStateRoot.appendingPathComponent(
                        "chat-runner-authority-local-internal-v1",
                        isDirectory: true)),
                remoteBorrowAuthorizationStore:
                    TatwoRemoteBorrowAuthorizationStore(
                        rootURL: resolvedStateRoot.appendingPathComponent(
                            "remote-execution-authorization-local-internal",
                            isDirectory: true)),
                remoteTurnDispatcher: ChatUnavailableRemoteTurnDispatcher())
        case .isolated:
            return TatwoChatProcessComposition(
                processClass: .isolated,
                storage: storage,
                stateRootURL: resolvedStateRoot,
                nativeChatStore: nativeChatStore,
                preferenceStore: preferenceStore,
                pluginRegistryStore: pluginRegistryStore,
                goalRunStore: goalRunStore,
                dispatchRegistry: dispatchRegistry,
                plgChainStore: plgChainStore,
                pendingRemoteTargetStore: pendingRemoteTargetStore,
                cancellationStateStore: cancellationStateStore,
                runnerAuthority: ChatDurableRunnerAuthority(
                    rootURL: resolvedStateRoot.appendingPathComponent(
                        "chat-runner-authority-v1",
                        isDirectory: true)),
                remoteBorrowAuthorizationStore:
                    TatwoRemoteBorrowAuthorizationStore(
                        rootURL: resolvedStateRoot.appendingPathComponent(
                            "remote-execution-authorization",
                            isDirectory: true)),
                remoteTurnDispatcher: ChatUnavailableRemoteTurnDispatcher())
        }
    }

    private static func stateRoot(
        for processClass: TatwoChatProcessClass,
        environment: [String: String],
        bundleIdentifier: String?,
        bundleURL: URL,
        applicationSupportBase: URL?,
        fileManager: FileManager,
        processID: Int32
    ) -> URL {
        let productionRoot = TatwoProductionLayoutLock.osNativeStateRoot(
            applicationSupportBase: applicationSupportBase,
            fileManager: fileManager)
        guard processClass == .isolated else {
            // Production layout has zero TATWO_* environment influence.
            return productionRoot
        }

        let candidate: URL?
        if let state = nonempty(
            environment[TatwoProductionLayoutLock.stateDirEnvKey])
        {
            candidate = URL(
                fileURLWithPath: state,
                isDirectory: true)
                .standardizedFileURL
        } else if let appSupport = nonempty(
            environment[TatwoProductionLayoutLock.appSupportEnvKey])
        {
            candidate = URL(
                fileURLWithPath: appSupport,
                isDirectory: true)
                .standardizedFileURL
                .appendingPathComponent("state", isDirectory: true)
        } else {
            candidate = nil
        }

        let productionAppSupport =
            TatwoProductionLayoutLock.osNativeApplicationSupportRoot(
                applicationSupportBase: applicationSupportBase,
                fileManager: fileManager)
        if let candidate,
           !isWithin(
                candidate,
                protectedRoot: productionAppSupport)
        {
            return candidate
        }

        let base: URL
        if bundleURL.pathExtension.lowercased() == "xctest"
            || bundleIdentifier?.lowercased().contains("xctest") == true
            || bundleIdentifier?.lowercased().hasSuffix(".tests") == true
        {
            base = fileManager.temporaryDirectory
                .appendingPathComponent(
                    "tatwo-ultrawork-tests",
                    isDirectory: true)
                .appendingPathComponent(
                    "process-\(processID)",
                    isDirectory: true)
        } else {
            base =
                applicationSupportBase
                ?? fileManager.urls(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask
                ).first
                ?? fileManager.temporaryDirectory
        }
        let identity = safePathComponent(
            bundleIdentifier
                ?? "unbundled-\(processID)")
        return base.standardizedFileURL
            .appendingPathComponent(
                "Tatwo Ultrawork Isolated",
                isDirectory: true)
            .appendingPathComponent(identity, isDirectory: true)
            .appendingPathComponent("state", isDirectory: true)
    }

    private static func isExactCanonicalProductionBundle(
        _ bundleURL: URL,
        expected: URL
    ) -> Bool {
        let supplied = bundleURL.standardizedFileURL
        let canonicalExpected = expected.standardizedFileURL
        guard supplied.path == canonicalExpected.path else {
            return false
        }
        let resolvedSupplied =
            supplied.resolvingSymlinksInPath().standardizedFileURL
        let resolvedExpected =
            canonicalExpected.resolvingSymlinksInPath().standardizedFileURL
        return resolvedSupplied.path == supplied.path
            && resolvedExpected.path == canonicalExpected.path
            && resolvedSupplied.path == resolvedExpected.path
    }

    private static func systemProductionSignatureTrust(
        bundleURL: URL
    ) -> TatwoProductionCodeSignatureTrust {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(
            bundleURL.standardizedFileURL as CFURL,
            SecCSFlags(),
            &staticCode) == errSecSuccess,
              let staticCode
        else {
            return .unknown
        }

        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(
            productionDesignatedRequirement as CFString,
            SecCSFlags(),
            &requirement) == errSecSuccess,
              let requirement
        else {
            return .unknown
        }

        let validationFlags = SecCSFlags(rawValue:
            kSecCSStrictValidate
                | kSecCSCheckAllArchitectures
                | kSecCSCheckNestedCode)
        if SecStaticCodeCheckValidity(
            staticCode,
            validationFlags,
            requirement) == errSecSuccess
        {
            return .trusted
        }

        // The current local-internal track is intentionally ad-hoc until the
        // Developer ID human gate is completed. It still needs a valid,
        // internally consistent code signature before receipt/anchor evidence
        // is considered.
        guard SecStaticCodeCheckValidity(
            staticCode,
            validationFlags,
            nil) == errSecSuccess
        else {
            return .rejected
        }
        var signingInformation: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &signingInformation) == errSecSuccess,
              let values = signingInformation as? [String: Any],
              let rawFlags =
                (values[kSecCodeInfoFlags as String] as? NSNumber)?
                    .uint32Value
        else {
            return .unknown
        }
        let teamIdentifier =
            (values[kSecCodeInfoTeamIdentifier as String] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        guard rawFlags & adHocCodeSignatureFlag != 0,
              teamIdentifier == nil || teamIdentifier?.isEmpty == true
        else {
            return .rejected
        }
        return .currentAdHoc
    }

    static func productionPromotionTrust(
        bundleURL: URL,
        infoDictionary: [String: Any],
        applicationSupportBase: URL?,
        fileManager: FileManager = .default,
        bundleCDHashProvider:
            ProductionBundleCDHashProvider = systemProductionBundleCDHash
    ) -> TatwoProductionPromotionTrust {
        let stateRoot = TatwoProductionLayoutLock.osNativeStateRoot(
            applicationSupportBase: applicationSupportBase,
            fileManager: fileManager)
        let promotionRoot = stateRoot.appendingPathComponent(
            productionPromotionDirectoryName,
            isDirectory: true)
        let manifestURL = promotionRoot.appendingPathComponent(
            productionPromotionManifestName,
            isDirectory: false)
        let signatureURL = promotionRoot.appendingPathComponent(
            productionPromotionSignatureName,
            isDirectory: false)
        let appcastURL = promotionRoot.appendingPathComponent(
            "appcast.xml",
            isDirectory: false)
        guard safeRegularFile(manifestURL, fileManager: fileManager),
              safeRegularFile(signatureURL, fileManager: fileManager),
              safeRegularFile(appcastURL, fileManager: fileManager)
        else {
            return .unknown
        }
        guard let manifestData = try? Data(contentsOf: manifestURL),
              !manifestData.isEmpty,
              manifestData.count <= 1024 * 1024,
              let signatureText = try? String(
                contentsOf: signatureURL,
                encoding: .utf8
              ).trimmingCharacters(in: .whitespacesAndNewlines),
              let signature = Data(base64Encoded: signatureText),
              signature.count == 64,
              signature.base64EncodedString() == signatureText,
              let publicKeyText =
                nonempty(infoDictionary["SUPublicEDKey"] as? String),
              let publicKeyData = Data(base64Encoded: publicKeyText),
              publicKeyData.count == 32,
              publicKeyData.base64EncodedString() == publicKeyText,
              let publicKey = try? Curve25519.Signing.PublicKey(
                rawRepresentation: publicKeyData),
              publicKey.isValidSignature(signature, for: manifestData),
              let manifest = try? JSONDecoder().decode(
                SignedReleaseManifest.self,
                from: manifestData),
              manifest.schema == "TatwoSignedReleaseManifestV1",
              let version = nonempty(
                infoDictionary["CFBundleShortVersionString"] as? String),
              let build = nonempty(
                infoDictionary["CFBundleVersion"] as? String),
              let executable = nonempty(
                infoDictionary["CFBundleExecutable"] as? String),
              let feedURL = nonempty(
                infoDictionary["SUFeedURL"] as? String),
              let channel = nonempty(
                infoDictionary["TatwoUpdateChannel"] as? String),
              channel == "internal-canary" || channel == "stable",
              let sourceCommit = nonempty(
                infoDictionary[sourceCommitInfoKey] as? String),
              let sourceTree = nonempty(
                infoDictionary[sourceTreeInfoKey] as? String),
              let helperSHA256 = nonempty(
                infoDictionary[productionHelperDigestInfoKey] as? String),
              let bundleCDHash = bundleCDHashProvider(bundleURL)?
                .lowercased(),
              manifest.version == version,
              manifest.build == build,
              manifest.channel == channel,
              manifest.feedURL == feedURL,
              manifest.bundle.identifier
                == TatwoRuntimeLayout.bundleIdentifier,
              manifest.bundle.executable == executable,
              manifest.bundle.cdhash == bundleCDHash,
              manifest.bundle.helperSHA256 == helperSHA256,
              manifest.provenance.sourceCommit == sourceCommit,
              manifest.provenance.sourceTree == sourceTree,
              manifest.provenance.developerIDTeamID
                == expectedProductionTeamIdentifier,
              manifest.provenance.notarizationStatus == "Accepted",
              !manifest.provenance.notarizationSubmissionID.isEmpty,
              isLowercaseHex(manifest.artifact.sha256, count: 64),
              manifest.artifact.bytes > 0,
              !manifest.artifact.sparkleEdDSASignature.isEmpty,
              isLowercaseHex(
                manifest.updateEvidence.appcastSHA256,
                count: 64),
              let appcastData = try? Data(contentsOf: appcastURL),
              !appcastData.isEmpty,
              appcastData.count <= 16 * 1024 * 1024,
              sha256Hex(appcastData)
                == manifest.updateEvidence.appcastSHA256
        else {
            return .rejected
        }
        return .trusted
    }

    private static func systemProductionPromotionTrust(
        _ bundleURL: URL,
        _ infoDictionary: [String: Any],
        _ applicationSupportBase: URL?,
        _ fileManager: FileManager
    ) -> TatwoProductionPromotionTrust {
        productionPromotionTrust(
            bundleURL: bundleURL,
            infoDictionary: infoDictionary,
            applicationSupportBase: applicationSupportBase,
            fileManager: fileManager)
    }

    private static func systemProductionBundleCDHash(
        bundleURL: URL
    ) -> String? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(
            bundleURL.standardizedFileURL as CFURL,
            SecCSFlags(),
            &staticCode) == errSecSuccess,
              let staticCode
        else {
            return nil
        }
        var signingInformation: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &signingInformation) == errSecSuccess,
              let values = signingInformation as? [String: Any],
              let digest = values[kSecCodeInfoUnique as String] as? Data,
              digest.count >= 20
        else {
            return nil
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func localInternalInstallTrust(
        bundleURL: URL,
        infoDictionary: [String: Any],
        applicationSupportBase: URL?,
        expectedProductionBundleURL: URL = canonicalProductionBundleURL,
        expectedSignatureTrust:
            TatwoProductionCodeSignatureTrust? = nil,
        fileManager: FileManager = .default,
        localInstallAnchorProvider:
            () throws -> TatwoLocalInternalInstallAnchorV1?,
        bundleContentDigestProvider:
            BundleContentDigestProvider = systemBundleContentDigest
    ) -> TatwoLocalInternalInstallTrust {
        let canonicalBundle =
            expectedProductionBundleURL.standardizedFileURL
        guard bundleURL.standardizedFileURL.path == canonicalBundle.path,
              infoDictionary[buildClassInfoKey] as? String
                == localInternalBuildClass,
              strictBooleanMarker(
                infoDictionary[distributionReadyInfoKey]) == false,
              strictBooleanMarker(
                infoDictionary[automaticUpdatesInfoKey]) == false,
              let sourceCommit =
                infoDictionary[sourceCommitInfoKey] as? String,
              let sourceTree =
                infoDictionary[sourceTreeInfoKey] as? String,
              let candidateID =
                infoDictionary[candidateIDInfoKey] as? String,
              let sourceDirty = strictBooleanMarker(
                infoDictionary[sourceDirtyInfoKey]),
              let sourceSnapshotDigest =
                infoDictionary[
                    sourceSnapshotDigestInfoKey
                ] as? String,
              let sourceTreeManifestDigest =
                infoDictionary[
                    sourceTreeManifestDigestInfoKey
                ] as? String,
              let buildInputManifestDigest =
                infoDictionary[
                    buildInputManifestDigestInfoKey
                ] as? String,
              let buildOutputManifestDigest =
                infoDictionary[
                    buildOutputManifestDigestInfoKey
                ] as? String,
              let embeddedProvenanceDigest =
                infoDictionary[
                    embeddedProvenanceDigestInfoKey
                ] as? String,
              let provenanceNodeDigest =
                infoDictionary[
                    provenanceNodeDigestInfoKey
                ] as? String,
              let provenanceNodeCDHash =
                infoDictionary[
                    provenanceNodeCDHashInfoKey
                ] as? String,
              let provenanceNodeVersion = nonempty(
                infoDictionary[
                    provenanceNodeVersionInfoKey
                ] as? String),
              let helperDigest =
                infoDictionary[productionHelperDigestInfoKey] as? String,
              let bundleContentManifestDigest =
                infoDictionary[
                    bundleContentManifestDigestInfoKey
                ] as? String,
              let mainExecutableDigest =
                infoDictionary[mainExecutableDigestInfoKey] as? String,
              let appVersion = nonempty(
                infoDictionary["CFBundleShortVersionString"] as? String),
              let appBuild = nonempty(
                infoDictionary["CFBundleVersion"] as? String),
              isLowercaseHex(sourceCommit, count: 40),
              isLowercaseHex(sourceTree, count: 40),
              isLowercaseHex(candidateID, count: 64),
              isLowercaseHex(sourceSnapshotDigest, count: 64),
              isLowercaseHex(
                sourceTreeManifestDigest,
                count: 64),
              isLowercaseHex(
                buildInputManifestDigest,
                count: 64),
              isLowercaseHex(
                buildOutputManifestDigest,
                count: 64),
              isLowercaseHex(
                embeddedProvenanceDigest,
                count: 64),
              isLowercaseHex(provenanceNodeDigest, count: 64),
              isLowercaseHex(provenanceNodeCDHash, count: 40),
              isLowercaseHex(helperDigest, count: 64),
              isLowercaseHex(bundleContentManifestDigest, count: 64),
              isLowercaseHex(mainExecutableDigest, count: 64),
              candidateID == computedCandidateID(
                sourceCommit: sourceCommit,
                sourceTree: sourceTree,
                sourceSnapshotDigest: sourceSnapshotDigest,
                sourceTreeManifestDigest:
                    sourceTreeManifestDigest,
                buildInputManifestDigest:
                    buildInputManifestDigest,
                buildOutputManifestDigest:
                    buildOutputManifestDigest,
                bundleContentManifestDigest:
                    bundleContentManifestDigest,
                mainExecutableDigest: mainExecutableDigest,
                provenanceNodeDigest: provenanceNodeDigest,
                provenanceNodeCDHash: provenanceNodeCDHash,
                provenanceNodeVersion: provenanceNodeVersion,
                appVersion: appVersion,
                appBuild: appBuild)
        else {
            return .rejected
        }

        let appSupport =
            TatwoProductionLayoutLock.osNativeApplicationSupportRoot(
                applicationSupportBase: applicationSupportBase,
                fileManager: fileManager)
        let stateRoot =
            TatwoProductionLayoutLock.osNativeStateRoot(
                applicationSupportBase: applicationSupportBase,
                fileManager: fileManager)
        let anchor: TatwoLocalInternalInstallAnchorV1
        do {
            guard let loadedAnchor = try localInstallAnchorProvider() else {
                return .rejected
            }
            anchor = loadedAnchor
        } catch {
            return .unknown
        }
        let deviceIdentityURL = appSupport.appendingPathComponent(
            "device-identity.json",
            isDirectory: false)
        guard anchor.schema == "TatwoLocalInternalInstallAnchorV1",
              anchor.candidateID == candidateID,
              anchor.canonicalAppPath == canonicalBundle.path,
              anchor.canonicalStateRoot
                == stateRoot.standardizedFileURL.path,
              anchor.installGeneration > 0,
              iso8601Date(anchor.createdAt) != nil,
              safeRegularFile(
                deviceIdentityURL,
                fileManager: fileManager),
              let deviceIdentityData = try? Data(
                contentsOf: deviceIdentityURL),
              !deviceIdentityData.isEmpty,
              deviceIdentityData.count <= 16 * 1024,
              let deviceIdentity = try? JSONDecoder().decode(
                LocalDeviceIdentity.self,
                from: deviceIdentityData),
              let deviceID = nonempty(
                deviceIdentity.deviceId),
              deviceID == anchor.deviceID
        else {
            return .rejected
        }

        let helperURL = bundleURL.appendingPathComponent(
            "Contents/Helpers/TatwoPLGAnchorHelper",
            isDirectory: false)
        guard safeRegularFile(helperURL, fileManager: fileManager),
              let helperData = try? Data(contentsOf: helperURL),
              SHA256.hash(data: helperData)
                .map({ String(format: "%02x", $0) })
                .joined() == helperDigest
        else {
            return .rejected
        }
        guard verifyBundleContentManifest(
            bundleURL: bundleURL,
            expectedManifestDigest: bundleContentManifestDigest,
            expectedMainExecutableDigest: mainExecutableDigest,
            fileManager: fileManager,
            digestProvider: bundleContentDigestProvider)
        else {
            return .rejected
        }
        let embeddedProvenanceURL = bundleURL.appendingPathComponent(
            "Contents/Resources/TatwoCandidateProvenance.json",
            isDirectory: false)
        guard safeRegularFile(
                embeddedProvenanceURL,
                fileManager: fileManager),
              let embeddedProvenanceData = try? Data(
                contentsOf: embeddedProvenanceURL),
              !embeddedProvenanceData.isEmpty,
              embeddedProvenanceData.count <= 128 * 1024,
              sha256Hex(embeddedProvenanceData)
                == embeddedProvenanceDigest,
              let embeddedProvenance = try? JSONDecoder().decode(
                EmbeddedCandidateProvenance.self,
                from: embeddedProvenanceData),
              embeddedProvenance.schema
                == "TatwoCandidateEmbeddedProvenanceV1",
              embeddedProvenance.candidateID == candidateID,
              embeddedProvenance.sourceCommit == sourceCommit,
              embeddedProvenance.sourceTree == sourceTree,
              embeddedProvenance.sourceDirty == sourceDirty,
              embeddedProvenance.sourceSnapshotSHA256
                == sourceSnapshotDigest,
              embeddedProvenance.sourceTreeManifestSHA256
                == sourceTreeManifestDigest,
              embeddedProvenance.buildInputManifestSHA256
                == buildInputManifestDigest,
              embeddedProvenance.buildOutputManifestSHA256
                == buildOutputManifestDigest,
              embeddedProvenance.bundleContentManifestSHA256
                == bundleContentManifestDigest,
              embeddedProvenance.mainExecutableSHA256
                == mainExecutableDigest,
              embeddedProvenance.provenanceNodeSHA256
                == provenanceNodeDigest,
              embeddedProvenance.provenanceNodeCDHash
                == provenanceNodeCDHash,
              embeddedProvenance.provenanceNodeVersion
                == provenanceNodeVersion
        else {
            return .rejected
        }

        let installerRoot = appSupport.appendingPathComponent(
            "local-app-install",
            isDirectory: true)
        let receiptDirectory = installerRoot
            .appendingPathComponent("receipts", isDirectory: true)
        let receiptPointerURL = receiptDirectory
            .appendingPathComponent(
                "latest-local-app-install.txt",
                isDirectory: false)
        guard safeRegularFile(
                receiptPointerURL,
                fileManager: fileManager),
              let pointerData = try? Data(
                contentsOf: receiptPointerURL),
              !pointerData.isEmpty,
              pointerData.count <= 16 * 1024,
              sha256Hex(pointerData) == anchor.pointerSHA256,
              let pointerText = String(
                data: pointerData,
                encoding: .utf8),
              let pointer = parseKeyValueReceipt(pointerText),
              Set(pointer.keys) == Set([
                "schema",
                "receipt_id",
                "receipt_filename",
                "receipt_sha256",
                "candidate_id",
              ]),
              pointer["schema"]
                == "TatwoLocalAppInstallReceiptPointerV1",
              let receiptID = pointer["receipt_id"],
              isLowercaseHex(receiptID, count: 64),
              receiptID == anchor.receiptID,
              let receiptFilename = pointer["receipt_filename"],
              isSafeInstallReceiptFilename(
                receiptFilename,
                receiptID: receiptID),
              receiptFilename == anchor.receiptFilename,
              let receiptDigest = pointer["receipt_sha256"],
              isLowercaseHex(receiptDigest, count: 64),
              receiptDigest == anchor.receiptSHA256,
              pointer["candidate_id"] == candidateID
        else {
            return .rejected
        }

        let receiptURL = receiptDirectory.appendingPathComponent(
            receiptFilename,
            isDirectory: false)
        guard safeRegularFile(receiptURL, fileManager: fileManager),
              let receiptData = try? Data(contentsOf: receiptURL),
              !receiptData.isEmpty,
              receiptData.count <= 64 * 1024,
              sha256Hex(receiptData) == receiptDigest,
              let receiptText = String(data: receiptData, encoding: .utf8),
              let receipt = parseKeyValueReceipt(receiptText),
              localInternalInstallReceiptIsClosedWorld(receipt),
              localInternalInstallReceiptForensicDigestsAreWellFormed(
                receipt),
              receipt["receipt_id"] == receiptID,
              let receiptNonce = receipt["receipt_nonce"],
              isLowercaseHex(receiptNonce, count: 64),
              receiptID == computedReceiptID(
                candidateID: candidateID,
                nonce: receiptNonce),
              receipt["receipt_filename"] == receiptFilename,
              receipt["candidate_id"] == candidateID,
              localInternalReceiptSigningIsConsistent(
                receipt,
                expectedSignatureTrust: expectedSignatureTrust),
              receipt["dry_run"] == "0",
              receipt["app_bundle"] == canonicalBundle.path,
              receipt["app_version"] == appVersion,
              receipt["app_build"] == appBuild,
              receipt["source_commit"] == sourceCommit,
              receipt["source_tree"] == sourceTree,
              receipt["source_dirty"]
                == (sourceDirty ? "true" : "false"),
              receipt["source_snapshot_sha256"]
                == sourceSnapshotDigest,
              receipt["source_tree_manifest_sha256"]
                == sourceTreeManifestDigest,
              receipt["build_input_manifest_sha256"]
                == buildInputManifestDigest,
              receipt["build_output_manifest_sha256"]
                == buildOutputManifestDigest,
              receipt["bundle_content_manifest_sha256"]
                == bundleContentManifestDigest,
              receipt["main_executable_sha256"]
                == mainExecutableDigest,
              receipt["embedded_provenance_sha256"]
                == embeddedProvenanceDigest,
              receipt["provenance_node_sha256"]
                == provenanceNodeDigest,
              receipt["provenance_node_cdhash"]
                == provenanceNodeCDHash,
              receipt["provenance_node_version"]
                == provenanceNodeVersion,
              receipt["stage_only"] == "0",
              let generatedAtString = receipt["generated_at"],
              iso8601Date(generatedAtString) != nil
        else {
            return .rejected
        }
        return .trusted
    }

    private static func localInternalInstallReceiptIsClosedWorld(
        _ receipt: [String: String]
    ) -> Bool {
        let forensicKeys: Set<String>
        switch receipt["schema"] {
        case "TatwoLocalAppInstallReceiptV2":
            // Legacy V2 used authority-looking names for two installer
            // readback digests. They are interpreted as forensic-only and
            // never compared with current bundle bytes at launch.
            forensicKeys = localInternalInstallReceiptV2ForensicKeys
        case "TatwoLocalAppInstallReceiptV3":
            forensicKeys = localInternalInstallReceiptV3ForensicKeys
        default:
            return false
        }
        return Set(receipt.keys)
            == localInternalInstallReceiptAuthorityKeys.union(forensicKeys)
    }

    private static func localInternalInstallReceiptForensicDigestsAreWellFormed(
        _ receipt: [String: String]
    ) -> Bool {
        let manifestKey: String
        let identityKey: String
        switch receipt["schema"] {
        case "TatwoLocalAppInstallReceiptV2":
            manifestKey = "staged_bundle_manifest_sha256"
            identityKey = "staged_bundle_identity_sha256"
        case "TatwoLocalAppInstallReceiptV3":
            manifestKey = "forensic_staged_bundle_manifest_sha256"
            identityKey = "forensic_staged_bundle_identity_sha256"
        default:
            return false
        }

        // Syntax validation keeps the versioned receipt closed-world. These
        // values are intentionally not launch authority: the referenced
        // installer-run artifacts are not a runtime source of truth. Current
        // bundle bytes, provenance, CandidateID, signature, and install anchor
        // are independently verified above.
        return isLowercaseHex(receipt[manifestKey], count: 64)
            && isLowercaseHex(receipt[identityKey], count: 64)
    }

    private static func verifyBundleContentManifest(
        bundleURL: URL,
        expectedManifestDigest: String,
        expectedMainExecutableDigest: String,
        fileManager: FileManager,
        digestProvider: BundleContentDigestProvider
    ) -> Bool {
        let bundle = bundleURL.standardizedFileURL
        let manifestURL = bundle.appendingPathComponent(
            bundleContentManifestRelativePath,
            isDirectory: false)
        guard safeRegularFile(manifestURL, fileManager: fileManager),
              let manifestData = try? Data(contentsOf: manifestURL),
              !manifestData.isEmpty,
              manifestData.count <= 8 * 1024 * 1024,
              sha256Hex(manifestData) == expectedManifestDigest,
              let manifest = try? JSONDecoder().decode(
                BundleContentManifest.self,
                from: manifestData),
              manifest.schema == "TatwoBundleContentManifestV1",
              manifest.exclusions == bundleContentManifestExclusions,
              !manifest.entries.isEmpty,
              manifest.entries.count <= 8_192,
              manifest.mainExecutable.path
                == "Contents/MacOS/TatwoUltraworkMac",
              manifest.mainExecutable.digestMode
                == "macho-adhoc-resign-strip-v1",
              isLowercaseHex(
                manifest.mainExecutable.sha256,
                count: 64),
              manifest.mainExecutable.sha256
                == expectedMainExecutableDigest
        else {
            return false
        }

        var priorPath: String?
        var expectedPaths = Set<String>()
        var mainEntryMatched = false
        for entry in manifest.entries {
            guard isSafeBundleRelativePath(entry.path),
                  !isBundleContentExcluded(entry.path),
                  expectedPaths.insert(entry.path).inserted,
                  priorPath.map({
                      utf8ByteOrderedBefore($0, entry.path)
                  }) ?? true,
                  isLowercaseHex(entry.sha256, count: 64)
            else {
                return false
            }
            priorPath = entry.path

            let fileURL = bundle.appendingPathComponent(
                entry.path,
                isDirectory: false)
            switch entry.type {
            case "file":
                guard entry.mode == "100644"
                        || entry.mode == "100755",
                      safeRegularFile(fileURL, fileManager: fileManager),
                      let attributes = try? fileManager.attributesOfItem(
                        atPath: fileURL.path),
                      let permissions =
                        (attributes[.posixPermissions] as? NSNumber)?
                            .uint16Value,
                      entry.mode == (
                        permissions & 0o111 == 0
                        ? "100644"
                        : "100755"),
                      entry.digestMode == "raw-sha256"
                        || entry.digestMode
                            == "macho-adhoc-resign-strip-v1",
                      let digest = digestProvider(
                        fileURL,
                        entry.digestMode,
                        fileManager),
                      digest.sha256 == entry.sha256,
                      digest.size == entry.size
                else {
                    return false
                }
            case "symlink":
                guard entry.mode == "120000",
                      entry.digestMode == "symlink-target-sha256",
                      isSymbolicLink(fileURL, fileManager: fileManager),
                      let destination =
                        try? fileManager.destinationOfSymbolicLink(
                            atPath: fileURL.path),
                      let destinationData = destination.data(
                        using: .utf8),
                      UInt64(destinationData.count) == entry.size,
                      sha256Hex(destinationData) == entry.sha256
                else {
                    return false
                }
            default:
                return false
            }

            if entry.path == manifest.mainExecutable.path {
                guard entry.type == "file",
                      entry.sha256 == manifest.mainExecutable.sha256,
                      entry.digestMode
                        == manifest.mainExecutable.digestMode
                else {
                    return false
                }
                mainEntryMatched = true
            }
        }
        guard mainEntryMatched,
              let actualPaths = actualBundleContentPaths(
                bundleURL: bundle,
                fileManager: fileManager),
              actualPaths == expectedPaths
        else {
            return false
        }
        return true
    }

    private static func isSafeInstallReceiptFilename(
        _ filename: String,
        receiptID: String
    ) -> Bool {
        filename == "local-app-install-\(receiptID).txt"
            && !filename.contains("/")
            && !filename.contains("\\")
            && filename != "."
            && filename != ".."
    }

    private static func actualBundleContentPaths(
        bundleURL: URL,
        fileManager: FileManager
    ) -> Set<String>? {
        var result = Set<String>()
        var failed = false
        let contentsURL = bundleURL.appendingPathComponent(
            "Contents",
            isDirectory: true)
        guard let enumerator = fileManager.enumerator(
            at: contentsURL,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ],
            options: [],
            errorHandler: { _, _ in
                failed = true
                return false
            })
        else {
            return nil
        }
        for case let url as URL in enumerator {
            guard let relativePath = bundleRelativePath(
                url,
                bundleURL: bundleURL)
            else {
                return nil
            }
            if isCodeSignatureDirectory(relativePath) {
                enumerator.skipDescendants()
                continue
            }
            if isBundleContentExcluded(relativePath) {
                continue
            }
            guard let values = try? url.resourceValues(
                forKeys: [
                    .isDirectoryKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                ])
            else {
                return nil
            }
            if values.isSymbolicLink == true {
                result.insert(relativePath)
                continue
            }
            if values.isDirectory == true {
                continue
            }
            guard values.isRegularFile == true else {
                return nil
            }
            result.insert(relativePath)
        }
        return failed ? nil : result
    }

    private static func bundleRelativePath(
        _ url: URL,
        bundleURL: URL
    ) -> String? {
        let root = bundleURL.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        let prefix = root.hasSuffix("/") ? root : "\(root)/"
        guard path.hasPrefix(prefix) else {
            return nil
        }
        let relative = String(path.dropFirst(prefix.count))
        return isSafeBundleRelativePath(relative) ? relative : nil
    }

    private static func isSafeBundleRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.contains("\0"),
              !path.contains("\\")
        else {
            return false
        }
        let components = path.split(
            separator: "/",
            omittingEmptySubsequences: false)
        return !components.isEmpty
            && components.allSatisfy {
                !$0.isEmpty && $0 != "." && $0 != ".."
            }
    }

    private static func isBundleContentExcluded(_ path: String) -> Bool {
        path == "Contents/Info.plist"
            || path.split(separator: "/").contains("_CodeSignature")
            || path == bundleContentManifestRelativePath
            || path
                == "Contents/Resources/TatwoCandidateProvenance.json"
    }

    private static func isCodeSignatureDirectory(_ path: String) -> Bool {
        path.hasPrefix("Contents/")
            && path.split(separator: "/").last == "_CodeSignature"
    }

    private static func utf8ByteOrderedBefore(
        _ lhs: String,
        _ rhs: String
    ) -> Bool {
        lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
    }

    private static func isSymbolicLink(
        _ url: URL,
        fileManager: FileManager
    ) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(
            atPath: url.path)
        else {
            return false
        }
        return attributes[.type] as? FileAttributeType
            == .typeSymbolicLink
    }

    private static func systemBundleContentDigest(
        fileURL: URL,
        digestMode: String,
        fileManager: FileManager
    ) -> BundleContentDigestResult? {
        guard safeRegularFile(fileURL, fileManager: fileManager) else {
            return nil
        }
        if digestMode == "raw-sha256" {
            guard let data = try? Data(contentsOf: fileURL) else {
                return nil
            }
            return BundleContentDigestResult(
                sha256: sha256Hex(data),
                size: UInt64(data.count))
        }
        guard digestMode == "macho-adhoc-resign-strip-v1" else {
            return nil
        }

        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent(
                "tatwo-bundle-content-\(UUID().uuidString)",
                isDirectory: true)
        let temporaryFile = temporaryRoot.appendingPathComponent(
            fileURL.lastPathComponent,
            isDirectory: false)
        do {
            try fileManager.createDirectory(
                at: temporaryRoot,
                withIntermediateDirectories: true)
            try fileManager.copyItem(at: fileURL, to: temporaryFile)
        } catch {
            try? fileManager.removeItem(at: temporaryRoot)
            return nil
        }
        defer {
            try? fileManager.removeItem(at: temporaryRoot)
        }

        _ = runCodesign(
            ["--remove-signature", temporaryFile.path])
        guard runCodesign([
            "-s", "-", "--force", "--timestamp=none",
            temporaryFile.path,
        ]),
              runCodesign([
                "--remove-signature",
                temporaryFile.path,
              ]),
              let normalizedData = try? Data(contentsOf: temporaryFile)
        else {
            return nil
        }
        return BundleContentDigestResult(
            sha256: sha256Hex(normalizedData),
            size: UInt64(normalizedData.count))
    }

    private static func runCodesign(_ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(
            fileURLWithPath: "/usr/bin/codesign",
            isDirectory: false)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationReason == .exit
                && process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func computedCandidateID(
        sourceCommit: String,
        sourceTree: String,
        sourceSnapshotDigest: String,
        sourceTreeManifestDigest: String,
        buildInputManifestDigest: String,
        buildOutputManifestDigest: String,
        bundleContentManifestDigest: String,
        mainExecutableDigest: String,
        provenanceNodeDigest: String,
        provenanceNodeCDHash: String,
        provenanceNodeVersion: String,
        appVersion: String,
        appBuild: String
    ) -> String {
        let payload = [
            sourceCommit,
            sourceTree,
            sourceSnapshotDigest,
            sourceTreeManifestDigest,
            buildInputManifestDigest,
            buildOutputManifestDigest,
            bundleContentManifestDigest,
            mainExecutableDigest,
            provenanceNodeDigest,
            provenanceNodeCDHash,
            provenanceNodeVersion,
            appVersion,
            appBuild,
        ].joined(separator: "\n") + "\n"
        return sha256Hex(Data(payload.utf8))
    }

    private static func computedReceiptID(
        candidateID: String,
        nonce: String
    ) -> String {
        sha256Hex(Data("\(candidateID)\n\(nonce)\n".utf8))
    }

    private static func localInternalReceiptSigningIsConsistent(
        _ receipt: [String: String],
        expectedSignatureTrust:
            TatwoProductionCodeSignatureTrust?
    ) -> Bool {
        let signingMode = receipt["signing_mode"]
        let coherent: Bool
        switch signingMode {
        case "ad-hoc":
            let identity = receipt["signing_identity"]
            coherent =
                receipt["signing"] == "ad-hoc"
                && receipt["distribution"]
                    == "local-internal-ad-hoc"
                && (identity == nil || identity == "-")
        case "developer-id":
            guard let identity = nonempty(
                receipt["signing_identity"]),
                  developerIDApplicationTeamIdentifier(identity)
                    == expectedProductionTeamIdentifier
            else {
                return false
            }
            coherent =
                receipt["signing"] == "developer-id \(identity)"
                && receipt["distribution"]
                    == "local-internal-developer-id"
        default:
            return false
        }
        guard coherent else {
            return false
        }

        switch expectedSignatureTrust {
        case .currentAdHoc:
            return signingMode == "ad-hoc"
        case .trusted:
            return signingMode == "developer-id"
        case .rejected, .unknown:
            return false
        case nil:
            return true
        }
    }

    private static func developerIDApplicationTeamIdentifier(
        _ identity: String
    ) -> String? {
        let prefix = "Developer ID Application: "
        guard identity.hasPrefix(prefix),
              identity.last == ")",
              let openingParenthesis = identity.lastIndex(of: "("),
              openingParenthesis > identity.index(
                identity.startIndex,
                offsetBy: prefix.count)
        else {
            return nil
        }

        let displayName = identity[
            identity.index(
                identity.startIndex,
                offsetBy: prefix.count)..<openingParenthesis
        ].trimmingCharacters(in: .whitespacesAndNewlines)
        let teamStart = identity.index(after: openingParenthesis)
        let teamEnd = identity.index(before: identity.endIndex)
        let teamIdentifier = String(identity[teamStart..<teamEnd])
        guard !displayName.isEmpty,
              teamIdentifier.count == expectedProductionTeamIdentifier.count,
              teamIdentifier.unicodeScalars.allSatisfy({
                  CharacterSet.uppercaseLetters.contains($0)
                      || CharacterSet.decimalDigits.contains($0)
              })
        else {
            return nil
        }
        return teamIdentifier
    }

    private static func systemLocalInternalInstallTrust(
        bundleURL: URL,
        infoDictionary: [String: Any],
        applicationSupportBase: URL?,
        fileManager: FileManager,
        signatureTrust: TatwoProductionCodeSignatureTrust
    ) -> TatwoLocalInternalInstallTrust {
        let appSupport =
            TatwoProductionLayoutLock.osNativeApplicationSupportRoot(
                applicationSupportBase: applicationSupportBase,
                fileManager: fileManager)
        let installerRoot = appSupport.appendingPathComponent(
            "local-app-install",
            isDirectory: true)
        return localInternalInstallTrust(
            bundleURL: bundleURL,
            infoDictionary: infoDictionary,
            applicationSupportBase: applicationSupportBase,
            expectedSignatureTrust: signatureTrust,
            fileManager: fileManager,
            localInstallAnchorProvider: {
                try TatwoLocalInternalInstallAnchorFileStore(
                    installerRootURL: installerRoot
                ).load()
            })
    }

    private static func parseKeyValueReceipt(
        _ value: String
    ) -> [String: String]? {
        var fields: [String: String] = [:]
        for rawLine in value.split(
            omittingEmptySubsequences: true,
            whereSeparator: \.isNewline)
        {
            let line = String(rawLine)
            guard let separator = line.firstIndex(of: "=") else {
                return nil
            }
            let key = String(line[..<separator])
            let fieldValue = String(line[line.index(after: separator)...])
            guard !key.isEmpty, fields[key] == nil else {
                return nil
            }
            fields[key] = fieldValue
        }
        return fields
    }

    private static func safeRegularFile(
        _ url: URL,
        fileManager: FileManager
    ) -> Bool {
        let standardized = url.standardizedFileURL
        guard standardized.resolvingSymlinksInPath().standardizedFileURL.path
                == standardized.path,
              let values = try? standardized.resourceValues(
                forKeys: [
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                ]),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              let attributes = try? fileManager.attributesOfItem(
                atPath: standardized.path),
              let owner = attributes[.ownerAccountID] as? NSNumber,
              owner.uint32Value == getuid(),
              let permissions =
                attributes[.posixPermissions] as? NSNumber,
              permissions.uint16Value & 0o022 == 0
        else {
            return false
        }
        return true
    }

    private static func iso8601Date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds,
        ]
        if let date = formatter.date(from: value) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private static func isWithin(
        _ candidate: URL,
        protectedRoot: URL
    ) -> Bool {
        let candidatePath =
            candidate.resolvingSymlinksInPath().standardizedFileURL.path
        let rootPath =
            protectedRoot.resolvingSymlinksInPath().standardizedFileURL.path
        return candidatePath == rootPath
            || candidatePath.hasPrefix(rootPath + "/")
    }

    private static func safePathComponent(_ value: String) -> String {
        let mapped = value.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar)
                || scalar.value == 45
                || scalar.value == 95
                || scalar.value == 46
            {
                return Character(String(scalar))
            }
            return "-"
        }
        let result = String(mapped).trimmingCharacters(
            in: CharacterSet(charactersIn: ".-"))
        return result.isEmpty ? "unidentified-process" : result
    }

    private static func isLowercaseHex(
        _ value: String?,
        count: Int
    ) -> Bool {
        guard let value, value.count == count else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            (48...57).contains(scalar.value)
                || (97...102).contains(scalar.value)
        }
    }

    private static func strictBooleanMarker(
        _ value: Any?
    ) -> Bool? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID()
        else {
            return nil
        }
        return number.boolValue
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(
            in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else {
            return nil
        }
        return trimmed
    }
}

enum ChatProductionRemoteTurnDispatcherError:
    Error, LocalizedError, Sendable, Equatable
{
    case invalidIdentifier(String)
    case unsupportedRoute
    case manifestMissing
    case manifestNotRegularFile
    case manifestUnreadable
    case manifestStale
    case manifestMismatch(String)
    case contractModeMismatch
    case originAuthorityUnavailable
    case channelFailure

    var errorDescription: String? {
        switch self {
        case .invalidIdentifier(let field):
            "Invalid production Chat remote dispatch identifier: \(field)"
        case .unsupportedRoute:
            "Production Chat remote dispatch requires an active exact model route."
        case .manifestMissing:
            "Target readiness manifest is missing from the sealed channel."
        case .manifestNotRegularFile:
            "Target readiness manifest must be a regular non-symlink file."
        case .manifestUnreadable:
            "Target readiness manifest is unreadable."
        case .manifestStale:
            "Target readiness manifest is stale."
        case .manifestMismatch(let field):
            "Target readiness manifest scope mismatch: \(field)"
        case .contractModeMismatch:
            "Remote loop mode does not exactly match the canonical GoalRun."
        case .originAuthorityUnavailable:
            "The local device does not hold a current durable origin lease."
        case .channelFailure:
            "The production remote job channel rejected the dispatch."
        }
    }
}

struct ChatProductionRemoteDispatchMaterial: Sendable, Equatable {
    let originDeviceID: String
    let currentOriginLease: TatwoAuthorityLeaseV1
    let contractMode: TatwoLoopModeV1
    let targetReadinessManifest: TatwoRemoteDispatchReadinessManifestV1
    let readinessBinding: TatwoRemoteDispatchReadinessBindingV1
}

protocol ChatProductionRemoteDispatchMaterialProviding: Sendable {
    func material(
        for request: ChatRemoteTurnDispatchRequest,
        now: Date
    ) throws -> ChatProductionRemoteDispatchMaterial
}

struct ChatProductionRemoteDispatchManifestChannel: Sendable {
    static let readinessDirectoryName = "readiness"
    static let manifestsDirectoryName = "manifests"
    static let maximumManifestBytes = 1_048_576

    let channelRootURL: URL

    init(channelRootURL: URL) {
        self.channelRootURL = channelRootURL.standardizedFileURL
    }

    static func manifestURL(
        channelRootURL: URL,
        targetDeviceID: String,
        agent: TatwoRemoteAgentKindV1,
        exactModelRouteID: String
    ) throws -> URL {
        guard TatwoLoopPathComponent.isValid(targetDeviceID) else {
            throw ChatProductionRemoteTurnDispatcherError.invalidIdentifier(
                "targetDeviceID")
        }
        guard TatwoLoopPathComponent.isValid(agent.rawValue) else {
            throw ChatProductionRemoteTurnDispatcherError.invalidIdentifier(
                "agent")
        }
        guard
            TatwoModelIdentityRegistry.canonicalModelID(
                for: exactModelRouteID) == exactModelRouteID,
            TatwoModelIdentityRegistry.isActiveDispatchEligible(
                exactModelRouteID),
            agent.acceptsExactModelRouteID(exactModelRouteID)
        else {
            throw ChatProductionRemoteTurnDispatcherError.unsupportedRoute
        }
        let digest = TatwoLoopJobDigest.sha256(Data(exactModelRouteID.utf8))
            .replacingOccurrences(of: "sha256:", with: "")
        let routeComponent = "route-\(digest)"
        guard TatwoLoopPathComponent.isValid(routeComponent) else {
            throw ChatProductionRemoteTurnDispatcherError.invalidIdentifier(
                "exactModelRouteID")
        }
        return channelRootURL.standardizedFileURL
            .appendingPathComponent(
                Self.readinessDirectoryName,
                isDirectory: true)
            .appendingPathComponent(
                Self.manifestsDirectoryName,
                isDirectory: true)
            .appendingPathComponent(targetDeviceID, isDirectory: true)
            .appendingPathComponent(agent.rawValue, isDirectory: true)
            .appendingPathComponent("\(routeComponent).json", isDirectory: false)
    }

    func load(
        targetDeviceID: String,
        agent: TatwoRemoteAgentKindV1,
        exactModelRouteID: String,
        now: Date
    ) throws -> TatwoRemoteDispatchReadinessManifestV1 {
        let fileManager = FileManager.default
        let url = try Self.manifestURL(
            channelRootURL: channelRootURL,
            targetDeviceID: targetDeviceID,
            agent: agent,
            exactModelRouteID: exactModelRouteID)
        guard fileManager.fileExists(atPath: url.path) else {
            throw ChatProductionRemoteTurnDispatcherError.manifestMissing
        }
        guard url.standardizedFileURL.path
            == url.resolvingSymlinksInPath().standardizedFileURL.path
        else {
            throw ChatProductionRemoteTurnDispatcherError.manifestNotRegularFile
        }
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try fileManager.attributesOfItem(atPath: url.path)
        } catch {
            throw ChatProductionRemoteTurnDispatcherError.manifestUnreadable
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let byteCount = attributes[.size] as? NSNumber,
              byteCount.intValue > 0,
              byteCount.intValue <= Self.maximumManifestBytes
        else {
            throw ChatProductionRemoteTurnDispatcherError.manifestNotRegularFile
        }
        let data: Data
        do {
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw ChatProductionRemoteTurnDispatcherError.manifestUnreadable
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest: TatwoRemoteDispatchReadinessManifestV1
        do {
            manifest = try decoder.decode(
                TatwoRemoteDispatchReadinessManifestV1.self,
                from: data)
        } catch {
            throw ChatProductionRemoteTurnDispatcherError.manifestUnreadable
        }
        guard manifest.schema
            == TatwoRemoteDispatchReadinessManifestV1.schemaName,
              manifest.targetDeviceID == targetDeviceID,
              manifest.requestedAgent == agent.rawValue,
              manifest.exactModelRouteID == exactModelRouteID,
              manifest.registryGeneration > 0,
              !manifest.workspaceBindingID.isEmpty
        else {
            throw ChatProductionRemoteTurnDispatcherError.manifestMismatch(
                "target-agent-route-workspace")
        }
        guard manifest.expiresAt > manifest.issuedAt,
              manifest.expiresAt.timeIntervalSince(manifest.issuedAt)
                <= TatwoRemoteDispatchReadinessManifestV1.maximumLifetime,
              manifest.issuedAt
                <= now.addingTimeInterval(
                    TatwoRemoteDispatchReadinessManifestV1.allowedClockSkew)
        else {
            throw ChatProductionRemoteTurnDispatcherError.manifestMismatch(
                "freshness-window")
        }
        guard manifest.expiresAt > now else {
            throw ChatProductionRemoteTurnDispatcherError.manifestStale
        }
        guard manifest.targetSignature.deviceID == targetDeviceID,
              manifest.targetSignature.keyID == manifest.targetKeyID,
              manifest.targetSignature.keyGeneration
                == manifest.targetKeyGeneration,
              manifest.targetSignature.signedAt
                == TatwoLoopJobChannelTrust.iso8601(manifest.issuedAt)
        else {
            throw ChatProductionRemoteTurnDispatcherError.manifestMismatch(
                "target-signature")
        }
        return manifest
    }
}

struct ChatProductionRemoteDispatchMaterialProvider:
    ChatProductionRemoteDispatchMaterialProviding
{
    struct ResolvedOriginAuthority: Sendable, Equatable {
        let originDeviceID: String
        let lease: TatwoAuthorityLeaseV1
    }

    typealias IssuedContractLoader =
        @Sendable (_ contractID: String) throws -> TatwoStoredGoalRun
    typealias OriginAuthorityResolver =
        @Sendable (_ now: Date) throws -> ResolvedOriginAuthority
    typealias ChannelRootResolver =
        @Sendable (_ hostDeviceID: String) throws -> URL
    typealias ManifestLoader =
        @Sendable (
            _ channelRootURL: URL,
            _ targetDeviceID: String,
            _ agent: TatwoRemoteAgentKindV1,
            _ exactModelRouteID: String,
            _ now: Date
        ) throws -> TatwoRemoteDispatchReadinessManifestV1

    let issuedContractLoader: IssuedContractLoader
    let originAuthorityResolver: OriginAuthorityResolver
    let channelRootResolver: ChannelRootResolver
    let manifestLoader: ManifestLoader

    init(
        stateRootURL: URL,
        verifiedSnapshotLoader:
            @escaping @Sendable () -> TatwoDomainDeviceSnapshotV1?,
        channelRootResolver: @escaping ChannelRootResolver
    ) {
        let resolvedStateRootURL = stateRootURL.standardizedFileURL
        self.init(
            issuedContractLoader: { contractID in
                try TatwoGoalRunStore(
                    directoryURL: resolvedStateRootURL
                ).requireIssuedContract(contractID)
            },
            originAuthorityResolver: { now in
                let authority = TatwoActiveOriginLeaseProjector.project(
                    snapshotProvider: TatwoStaticDomainDeviceSnapshotProvider(
                        snapshot: verifiedSnapshotLoader(),
                        now: { now }),
                    stateRootURL: resolvedStateRootURL,
                    now: now)
                guard case let .ready(originDeviceID, lease) = authority else {
                    throw ChatProductionRemoteTurnDispatcherError
                        .originAuthorityUnavailable
                }
                return ResolvedOriginAuthority(
                    originDeviceID: originDeviceID,
                    lease: lease)
            },
            channelRootResolver: channelRootResolver)
    }

    init(
        issuedContractLoader:
            @escaping IssuedContractLoader,
        originAuthorityResolver:
            @escaping OriginAuthorityResolver,
        channelRootResolver:
            @escaping ChannelRootResolver,
        manifestLoader:
            @escaping ManifestLoader = {
                channelRootURL,
                targetDeviceID,
                agent,
                exactModelRouteID,
                now in
                try ChatProductionRemoteDispatchManifestChannel(
                    channelRootURL: channelRootURL
                ).load(
                    targetDeviceID: targetDeviceID,
                    agent: agent,
                    exactModelRouteID: exactModelRouteID,
                    now: now)
            }
    ) {
        self.issuedContractLoader = issuedContractLoader
        self.originAuthorityResolver = originAuthorityResolver
        self.channelRootResolver = channelRootResolver
        self.manifestLoader = manifestLoader
    }

    static func production() -> Self {
        Self(
            stateRootURL: TatwoProductionLayoutLock.osNativeStateRoot(),
            verifiedSnapshotLoader: {
                // Construct the non-Sendable disk provider inside this call
                // and publish only its immutable, validated value.
                TatwoDevicesCompositionRoot.makeProvider(
                    environment: [:]
                ).verifiedSnapshot()
            },
            channelRootResolver: { hostDeviceID in
                try TatwoProductionLayoutLock.resolve(
                    hostDeviceID: hostDeviceID,
                    requestedChannelRoot: nil,
                    environment: ProcessInfo.processInfo.environment,
                    installAnchorStore:
                        TatwoProductionInstallAnchorKeychainStore()
                ).jobChannelRoot
            })
    }

    func material(
        for request: ChatRemoteTurnDispatchRequest,
        now: Date
    ) throws -> ChatProductionRemoteDispatchMaterial {
        guard TatwoLoopPathComponent.isValid(request.readinessChallengeNonce)
        else {
            throw ChatProductionRemoteTurnDispatcherError.invalidIdentifier(
                "readinessChallengeNonce")
        }
        let goal = try issuedContractLoader(
            request.invocation.contractID)
        guard goal.goalID == request.invocation.goalID,
              goal.mode == request.contractMode,
              let loopMode = TatwoLoopModeV1(rawValue: goal.mode.rawValue)
        else {
            throw ChatProductionRemoteTurnDispatcherError.contractModeMismatch
        }

        let authority = try originAuthorityResolver(now)
        let originDeviceID = authority.originDeviceID
        let lease = authority.lease
        let channelRootURL = try channelRootResolver(originDeviceID)
        let manifest = try manifestLoader(
            channelRootURL,
            request.invocation.targetDeviceID,
            request.agent,
            request.exactModelRouteID,
            now)
        if let supplied = request.targetReadinessManifest,
           supplied != manifest
        {
            throw ChatProductionRemoteTurnDispatcherError.manifestMismatch(
                "preloaded-manifest")
        }
        let binding = manifest.binding(
            challengeNonce: request.readinessChallengeNonce)
        do {
            try binding.validate()
        } catch {
            throw ChatProductionRemoteTurnDispatcherError.manifestMismatch(
                "readiness-binding")
        }
        if let supplied = request.readinessBinding,
           supplied != binding
        {
            throw ChatProductionRemoteTurnDispatcherError.manifestMismatch(
                "preloaded-binding")
        }
        return ChatProductionRemoteDispatchMaterial(
            originDeviceID: originDeviceID,
            currentOriginLease: lease,
            contractMode: loopMode,
            targetReadinessManifest: manifest,
            readinessBinding: binding)
    }
}

struct ChatProductionRemoteTurnRunnerReceipt: Sendable, Equatable {
    let job: TatwoLoopJobV1
}

struct ChatProductionRemoteTurnDispatcher: ChatRemoteTurnDispatching {
    typealias Runner = @Sendable (
        _ originDeviceID: String,
        _ targetDeviceID: String,
        _ job: TatwoLoopJobV1,
        _ currentOriginLease: TatwoAuthorityLeaseV1,
        _ targetReadinessManifest: TatwoRemoteDispatchReadinessManifestV1
    ) throws -> ChatProductionRemoteTurnRunnerReceipt

    private let materialProvider:
        any ChatProductionRemoteDispatchMaterialProviding
    private let runner: Runner
    private let now: @Sendable () -> Date
    private let uniqueID: @Sendable () -> String

    init(
        materialProvider: any ChatProductionRemoteDispatchMaterialProviding,
        runner: @escaping Runner,
        now: @escaping @Sendable () -> Date = Date.init,
        uniqueID: @escaping @Sendable () -> String = {
            UUID().uuidString.lowercased()
        }
    ) {
        self.materialProvider = materialProvider
        self.runner = runner
        self.now = now
        self.uniqueID = uniqueID
    }

    static func production() -> Self {
        Self(
            materialProvider:
                ChatProductionRemoteDispatchMaterialProvider.production(),
            runner: {
                originDeviceID,
                targetDeviceID,
                job,
                currentOriginLease,
                targetReadinessManifest in
                let result = try TatwoLoopProductionRunnerBootstrap.dispatch(
                    originDeviceID: originDeviceID,
                    targetDeviceID: targetDeviceID,
                    job: job,
                    currentOriginLease: currentOriginLease,
                    targetReadinessManifest: targetReadinessManifest)
                return ChatProductionRemoteTurnRunnerReceipt(job: result.job)
            })
    }

    func dispatch(
        _ request: ChatRemoteTurnDispatchRequest
    ) -> ChatRemoteTurnDispatchOutcome {
        do {
            let currentTime = now()
            let material = try materialProvider.material(
                for: request,
                now: currentTime)
            guard material.contractMode.rawValue == request.contractMode.rawValue
            else {
                throw ChatProductionRemoteTurnDispatcherError
                    .contractModeMismatch
            }
            guard material.readinessBinding
                == material.targetReadinessManifest.binding(
                    challengeNonce: request.readinessChallengeNonce)
            else {
                throw ChatProductionRemoteTurnDispatcherError.manifestMismatch(
                    "attempt-readiness-binding")
            }
            let physicalID = uniqueID()
            let nonceID = uniqueID()
            guard TatwoLoopPathComponent.isValid(physicalID),
                  TatwoLoopPathComponent.isValid(nonceID)
            else {
                throw ChatProductionRemoteTurnDispatcherError.invalidIdentifier(
                    "attempt")
            }
            let job = TatwoLoopJobV1(
                jobID: "chat-\(physicalID)",
                logicalJobID: request.logicalJobID,
                dispatchNonce: "nonce-\(nonceID)",
                contractID: request.invocation.contractID,
                goalID: request.invocation.goalID,
                identity: .sub,
                originDeviceID: material.originDeviceID,
                targetDeviceID: request.invocation.targetDeviceID,
                remoteBorrowInvocation: request.invocation,
                remoteDispatchReadiness: material.readinessBinding,
                workspaceLocator: TatwoRemoteWorkspaceLocatorV1(
                    workspaceBindingID:
                        material.targetReadinessManifest.workspaceBindingID,
                    registryGeneration:
                        material.targetReadinessManifest.registryGeneration),
                payload: .tatwoLoop(
                    TatwoLoopPayloadV1(
                        contractID: request.invocation.contractID,
                        goalID: request.invocation.goalID,
                        identity: .sub,
                        mode: material.contractMode,
                        taskDescription: request.visibleTurn,
                        agent: request.agent,
                        exactModelRouteID: request.exactModelRouteID)),
                workPath: "",
                resourceCaps: TatwoLoopResourceCapsV1(
                    maxDurationSec:
                        TatwoLoopResourceCapsV1.localHardMaxDurationSec,
                    maxOutputBytes:
                        TatwoLoopResourceCapsV1.localHardMaxOutputBytes),
                stopConditions: TatwoLoopStopConditionsV1(
                    cancelFileSignal: true,
                    rules: [
                        "cancel-file",
                        "contract-drift",
                        "authority-lease-loss",
                    ]),
                createdAt: currentTime)
            try job.validate()
            let receipt = try runner(
                material.originDeviceID,
                request.invocation.targetDeviceID,
                job,
                material.currentOriginLease,
                material.targetReadinessManifest)
            guard receipt.job == job else {
                throw ChatProductionRemoteTurnDispatcherError.channelFailure
            }
            return .accepted(
                ChatRemoteTurnDispatchAcceptance(
                    logicalJobID: receipt.job.logicalJobID,
                    remoteJobID: receipt.job.jobID,
                    acceptedAt: receipt.job.createdAt))
        } catch {
            return .blocked(Self.blocker(for: error))
        }
    }

    private static func blocker(for error: Error) -> ChatRemoteTurnDispatchBlocker {
        switch error {
        case ChatProductionRemoteTurnDispatcherError.manifestMissing:
            return .readinessManifestMissing
        case ChatProductionRemoteTurnDispatcherError.manifestStale:
            return .readinessManifestStale
        case ChatProductionRemoteTurnDispatcherError.manifestMismatch,
             ChatProductionRemoteTurnDispatcherError.manifestNotRegularFile,
             ChatProductionRemoteTurnDispatcherError.manifestUnreadable,
             ChatProductionRemoteTurnDispatcherError.unsupportedRoute:
            return .readinessManifestMismatch
        case ChatProductionRemoteTurnDispatcherError.contractModeMismatch:
            return .contractModeMismatch
        case ChatProductionRemoteTurnDispatcherError.originAuthorityUnavailable:
            return .originLeaseLost
        case TatwoLoopProductionRunnerError.targetNotPinned,
             TatwoLoopProductionRunnerError.targetRevoked:
            return .targetTrustLost
        case TatwoLoopProductionRunnerError.missingOriginLease:
            return .originLeaseLost
        case TatwoLoopProductionRunnerError.missingChannelRoot,
             TatwoLoopProductionRunnerError.channelRootOverrideForbidden:
            return .adapterUnavailable
        default:
            return .dispatchRejected
        }
    }
}

/// User-visible outcome for one stale-handle fallback attempt on a Chat turn.
/// The coordinator never retries more than once.
enum ChatGatewayContinuationFallbackPresentation: Sendable, Equatable {
    /// Rebuild journal context, drop the handle, and retry the same turn.
    /// `notice` is optional and must never become a failed/issue row.
    case retryHandleless(notice: String?)
    /// Fallback already used, or retry is not allowed. Show one failed row
    /// using `message` (the latest error, not the original stale-handle code
    /// once a handle-less retry has run).
    case failedRow(message: String)
    /// Not a stale-handle class error.
    case notHandleError
}

struct ChatGatewayContinuationFallbackCoordinator: Sendable, Equatable {
    private(set) var fallbackAttempted: Bool
    private(set) var staleHandleCleared: Bool

    init(fallbackAttempted: Bool = false, staleHandleCleared: Bool = false) {
        self.fallbackAttempted = fallbackAttempted
        self.staleHandleCleared = staleHandleCleared
    }

    mutating func evaluateFailure(
        message: String,
        request: TatwoGatewayContinuationRequestV1?
    ) -> ChatGatewayContinuationFallbackPresentation {
        if TatwoGatewayContinuationStaleHandleFallbackV1.shouldClearStoredHandle(
            errorMessage: message,
            request: request)
        {
            staleHandleCleared = true
        }
        switch TatwoGatewayContinuationStaleHandleFallbackV1.decide(
            errorMessage: message,
            request: request,
            fallbackAlreadyAttempted: fallbackAttempted)
        {
        case .notApplicable:
            return .notHandleError
        case .retryWithoutHandle:
            fallbackAttempted = true
            return .retryHandleless(notice: nil)
        case .surfaceFailure:
            return .failedRow(message: message)
        }
    }
}

enum ChatRuntimeContinuationErrorMapping {
    /// Keep handle-unknown codes machine-readable so the fallback coordinator
    /// can classify them. Humanization happens only after fallback is exhausted.
    static func dispatchFailureMessage(_ message: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return message }
        if TatwoGatewayContinuationHandleErrorClassifierV1
            .isUnknownOrExpiredHandleError(trimmed),
           !trimmed.contains(
            TatwoGatewayContinuationHandleErrorClassifierV1.unknownOrExpiredCode)
        {
            return
                TatwoGatewayContinuationHandleErrorClassifierV1
                .unknownOrExpiredCode
                + ": "
                + trimmed
        }
        return trimmed
    }
}
