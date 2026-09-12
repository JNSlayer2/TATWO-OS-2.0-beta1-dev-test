import Foundation
import XCTest

final class PLGAppGovernanceSourceTests: XCTestCase {
    private var repoRoot: URL {
        ChatPageSourceScanner.repoRoot()
    }

    private var chatPageSource: String {
        get throws {
            try ChatPageSourceScanner.combinedSource(repoRoot: repoRoot)
        }
    }

    func testPLGAppUsesIssuedContractAndFailClosedDirectDispatch() throws {
        let source = try chatPageSource
        let suggestionSource = try readSource(
            "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/ChatComposerSuggestionCatalog.swift")
        let section = try XCTUnwrap(
            source.slice(
                from: "// MARK: #16 /plg 執行流",
                through: "/// #16 主 chat → loops 橋"))

        XCTAssertTrue(suggestionSource.contains("TatwoSlashCommandParser.replacingPartialCommand"))
        XCTAssertTrue(section.contains("ensureSelectedThreadWorkOSContract"))
        XCTAssertTrue(section.contains("requireIssuedContract"))
        XCTAssertTrue(section.contains("TatwoPLGGovernance.validateStartContext"))
        XCTAssertFalse(section.contains(#"?? "plg-"#))

        XCTAssertFalse(section.contains("appendPLGEventToLedger"))
        XCTAssertFalse(section.contains("appendLedgerLine"))
        XCTAssertFalse(section.contains("codex exec"))

        XCTAssertFalse(section.contains("gatewayDirectAdapterScriptURL"))
        XCTAssertFalse(section.contains("TatwoDispatchRegistry"))
        XCTAssertFalse(section.contains("canCoordinateContractBoundDispatch"))
        XCTAssertTrue(section.contains("TatwoWorkOSChokepoint"))
        XCTAssertFalse(section.contains("goalRunStore.appendReceipt"))
        XCTAssertTrue(section.contains("human_gate 必須由 Work OS/MCP 提交"))
        XCTAssertTrue(source.contains("TatwoPLGGovernance.canReuseIssuedContract"))
    }

    func testSlashCommandsShareSkillKeyboardNavigationAndVisibleSelection() throws {
        let source = try chatPageSource
        let handler = try XCTUnwrap(
            source.slice(
                from: "func handleSlashSuggestionKey",
                through: "func applySkillSuggestion"))
        let rail = try XCTUnwrap(
            source.slice(
                from: "func slashCommandRail",
                through: "func droppedAttachmentChip"))

        XCTAssertTrue(handler.contains("matchingSlashCommands"))
        XCTAssertTrue(handler.contains("slashCommandSelectedIndex"))
        XCTAssertTrue(handler.contains("applySlashCommandSuggestion"))
        XCTAssertTrue(handler.contains("case .next"))
        XCTAssertTrue(handler.contains("case .prev"))
        XCTAssertTrue(handler.contains("case .commit"))
        XCTAssertTrue(rail.contains("slashCommandSelectedIndex == idx"))
        XCTAssertTrue(rail.contains(".background("))
    }

    func testPlanAndGoalCommandsFollowCodexStyleLifecycleInsteadOfAliasingPLG() throws {
        let source = try chatPageSource
        let commands = try XCTUnwrap(
            source.slice(
                from: "static let slashCommandItems",
                through: "func authorizePLG"))
        let send = try XCTUnwrap(
            source.slice(
                from: "func send()",
                through: "struct PromptCollaborationIntent"))
        let goalRouting = try XCTUnwrap(
            source.slice(
                from: "func commitOrActivateGoalFromPrompt(",
                through: "func activateGoalFromPrompt("))

        XCTAssertTrue(commands.contains("applySlashCommandSuggestion"))
        XCTAssertFalse(commands.contains("runSlashCommand"))
        XCTAssertTrue(send.contains("""
            if matchesSlash(trimmed, "/plg") {
                            triggerPLGFromPrompt()
            """))
        XCTAssertTrue(send.contains("""
            if matchesSlash(trimmed, "/plan") {
                            handlePlanSlashCommand()
            """))
        XCTAssertTrue(send.contains("if matchesSlash(trimmed, \"/goal\") {"))
        XCTAssertTrue(send.contains("commitOrActivateGoalFromPrompt()"))
        XCTAssertFalse(send.contains("matchesSlash(trimmed, \"/plg\") || matchesSlash(trimmed, \"/plan\")"))
        XCTAssertTrue(goalRouting.contains("commitPLGGoalFromPrompt()"))
    }

    func testPLGAppCannotFinalizeGoalAndFlowCardSaysReady() throws {
        let chatSource = try chatPageSource
        let evaluation = try XCTUnwrap(
            chatSource.slice(
                from: "func evaluatePLGMainline",
                through: "func rollbackPLG"))
        XCTAssertTrue(evaluation.contains("guard !met else"))
        XCTAssertTrue(evaluation.contains("等待 Work OS close/gate"))

        let cardSource = try readSource(
            "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/PLGFlowCard.swift")
        XCTAssertFalse(cardSource.contains("達標·完成"))
        XCTAssertFalse(cardSource.contains("主線 goal 達標，完工提交人類"))
        XCTAssertTrue(cardSource.contains("收據 READY"))
        XCTAssertTrue(cardSource.contains("等待 Work OS close/gate"))
        XCTAssertTrue(cardSource.contains("blockerMessage"))
        XCTAssertTrue(cardSource.contains("PLG blocker"))
    }

    func testPolicyAAppHasNoDirectDispatchOrRegistryWritePath() throws {
        let source = try chatPageSource
        let section = try XCTUnwrap(
            source.slice(
                from: "// MARK: #16 /plg 執行流",
                through: "/// #16 主 chat → loops 橋"))

        XCTAssertFalse(source.contains("enum TatwoPLGDirectDispatchRuntime"))
        XCTAssertFalse(section.contains("TatwoPLGDirectDispatchRuntime"))
        XCTAssertFalse(section.contains("TatwoDispatchRegistry"))
        XCTAssertFalse(section.contains("gatewayDirectAdapterScriptURL"))
        XCTAssertFalse(section.contains("canCoordinateContractBoundDispatch"))
        XCTAssertTrue(section.contains("WorkOSChokepoint"))
    }

    func testPolicyDBranchesUseDomainScopedPlanSlices() throws {
        let source = try chatPageSource
        let section = try XCTUnwrap(
            source.slice(
                from: "// MARK: #16 /plg 執行流",
                through: "/// #16 主 chat → loops 橋"))
        let core = try readSource(
            "Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/TatwoPLGOrchestrator.swift")

        XCTAssertFalse(section.contains("let objective = run.planSummary"))
        XCTAssertTrue(section.contains("TatwoPLGPolicyDProjector.project"))
        XCTAssertTrue(core.contains("domainLoopID"))
        XCTAssertTrue(core.contains("planSlice"))
        XCTAssertTrue(core.contains("domainReceipt"))
    }

    func testPolicyDProjectionCannotMintPassOrSelectBindingsPositionally() throws {
        let source = try chatPageSource
        let projection = try XCTUnwrap(
            source.slice(
                from: "private func makePLGDomainProjection",
                through: "/// Rebuild only the App's PLG projection"))

        XCTAssertTrue(projection.contains("TatwoPLGPolicyDProjector.project"))
        XCTAssertFalse(projection.contains("submittedReceiptIDs"))
        XCTAssertFalse(projection.contains("TatwoPLGDomainReceipt("))
        XCTAssertFalse(projection.contains(".compactMap"))
        XCTAssertFalse(projection.contains("% subBindings.count"))
        XCTAssertFalse(projection.contains("reportedToMainline: domainReceipt != nil"))
        XCTAssertFalse(projection.contains("verdict: .pass"))
    }

    func testPolicyDSourceCarriesAuthoritativeLoopIdentityAndQuarantineRules() throws {
        let source = try readSource(
            "Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/TatwoPLGOrchestrator.swift")

        XCTAssertTrue(source.contains("sourceLoopID"))
        XCTAssertTrue(source.contains("ownerIdentity"))
        XCTAssertTrue(source.contains("duplicateSourceLoopID"))
        XCTAssertTrue(source.contains("Policy D migration quarantine"))
        XCTAssertTrue(source.contains("sourceLoopID: sourceLoopID"))
        XCTAssertTrue(source.contains("receiptPresentation"))
    }

    func testReceiptPresentationUsesPassFailBlockedStatesInsteadOfNonnilReceipt() throws {
        let source = try readSource(
            "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/PLGFlowCard.swift")

        XCTAssertTrue(source.contains("branchPresentation(for:"))
        XCTAssertTrue(source.contains("presentation.receipt"))
        XCTAssertTrue(source.contains("case .pass"))
        XCTAssertTrue(source.contains("case .fail"))
        XCTAssertTrue(source.contains("case .blocked"))
        XCTAssertFalse(source.contains("b.domainReceipt == nil"))
        XCTAssertFalse(source.contains(#""Domain receipt · PASS")"#))
    }

    func testFlowCardUsesOneRunAwarePresentationForAllAuthorityVisuals() throws {
        let source = try readSource(
            "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/PLGFlowCard.swift")

        XCTAssertTrue(source.contains("branchPresentation(for:"))
        XCTAssertTrue(source.contains("presentation.visualStatus"))
        XCTAssertTrue(source.contains("presentation.receipt"))
        XCTAssertTrue(source.contains("presentation.isVerifiedPass"))
        XCTAssertFalse(source.contains("branchColor(b.status)"))
        XCTAssertFalse(source.contains("branchStatusLabel(b.status)"))
        XCTAssertFalse(source.contains("filter { $0.status == .passed }"))
    }

    func testPLGRestoreReplaysAnchoredChainAndReconstructsEventIDs() throws {
        let source = try chatPageSource
        let restore = try XCTUnwrap(
            source.slice(
                from: "func restoreActivePLGProjection",
                through: "private func persistActivePLGProjection"))

        XCTAssertTrue(source.contains("TatwoPLGChainStore"))
        XCTAssertTrue(restore.contains("plgChainStore.replayUnique"))
        XCTAssertTrue(restore.contains("appliedPLGEventIDs = replay.appliedEventIDs"))
        XCTAssertTrue(restore.contains("plgAuthorityState = .verified"))
        XCTAssertTrue(restore.contains("plgAuthorityState = .quarantined"))
        XCTAssertTrue(restore.contains("activePLGRun = nil"))
        XCTAssertFalse(restore.contains("activePLGRun = projection"))
    }

    func testPLGStartPublishesOnlyVerifiedReplay() throws {
        let source = try chatPageSource
        let start = try XCTUnwrap(
            source.slice(
                from: "func startPLGRun",
                through: "private func makePLGDomainProjection"))

        XCTAssertTrue(start.contains("plgChainStore.begin"))
        XCTAssertTrue(start.contains("plgChainStore.replay"))
        XCTAssertTrue(start.contains("activePLGRun = replay.run"))
        XCTAssertTrue(start.contains("appliedPLGEventIDs = replay.appliedEventIDs"))
        XCTAssertTrue(start.contains("plgAuthorityState = .verified"))
        XCTAssertFalse(start.contains("activePLGRun = projected"))
    }

    func testPLGStartSurfacesTheRealFailClosedReason() throws {
        let source = try chatPageSource
        let start = try XCTUnwrap(
            source.slice(
                from: "func startPLGRun",
                through: "private func makePLGDomainProjection"))

        XCTAssertTrue(
            start.contains(
                "flashComposerHint(\"PLG 未啟動：\\(error.localizedDescription)\")"))
        XCTAssertFalse(
            start.contains(
                "flashComposerHint(\"PLG 未啟動：需要 Work OS 已簽發且 goal 相符的 contract。\")"))
    }

    func testStagingBuilderReusesRuntimeScopedKeychainIdentityAcrossBuilds() throws {
        let script = try readSource("script/build_staging_app.sh")

        XCTAssertTrue(script.contains("uuidgen"))
        XCTAssertTrue(script.contains("date -u"))
        XCTAssertTrue(
            script.contains("tatwo-staging-anchor-identity.py"))
        XCTAssertTrue(
            script.contains(
                "IFS=$'\\t' read -r ANCHOR_SERVICE ANCHOR_ACCOUNT"))
        XCTAssertTrue(
            script.contains("--runtime-root \"$STAGING_RUNTIME_ROOT\""))
        XCTAssertFalse(
            script.contains(
                "ANCHOR_SERVICE=\"ai.tatwo.ultrawork.plg-chain-anchor.staging.${STAMP}.${TOKEN}\""))
        XCTAssertFalse(
            script.contains(
                "ANCHOR_ACCOUNT=\"staging.${STAMP}.${TOKEN}\""))
        XCTAssertTrue(script.contains("TatwoPLGAnchorHelper"))
        XCTAssertTrue(script.contains("Tools/TatwoPLGAnchorHelper/main.c"))
        XCTAssertTrue(script.contains("TATWO_ULTRAWORK_PLG_ANCHOR_HELPER"))
        XCTAssertTrue(script.contains("TATWO_ULTRAWORK_PLG_ANCHOR_HELPER_SHA256"))
        XCTAssertTrue(script.contains("\"anchorHelperSHA256\""))
        XCTAssertTrue(script.contains("TATWO_ULTRAWORK_PLG_ANCHOR_SERVICE"))
        XCTAssertTrue(script.contains("TATWO_ULTRAWORK_PLG_ANCHOR_ACCOUNT"))
        XCTAssertTrue(script.contains("TATWO_ULTRAWORK_APP_SUPPORT"))
        XCTAssertTrue(script.contains("TATWO_ULTRAWORK_STATE_DIR"))
        XCTAssertTrue(script.contains("TATWO_STAGING_RUNTIME_ROOT"))
        XCTAssertTrue(script.contains("TATWO_STAGING_ALLOW_EXTERNAL_RUNTIME"))
        XCTAssertTrue(script.contains("\"runtimeRoot\""))
        XCTAssertTrue(script.contains("\"externalRuntimeAllowed\""))
        XCTAssertTrue(
            script.contains("<key>TatwoStagingRevisionIssuerScope</key>"))
        XCTAssertTrue(
            script.contains("<string>revision_activation_only</string>"))
        XCTAssertTrue(script.contains("/usr/bin/env -i"))
        // 2026-08-29：同一 staging slot 必須保留 runtime-scoped HOME，
        // 才能讓 WebKit cookie／登入／快取跟著該 slot，而不是落回正式使用者
        // HOME。建置工具需要的真實家目錄只走 BUILD_SHELL_HOME，不得洩漏到
        // App 的 LSEnvironment 或直接啟動環境。
        XCTAssertTrue(
            script.contains("\"HOME=$STAGING_HOME\""))
        XCTAssertTrue(
            script.contains("\"TATWO_STAGING_SCRATCH_HOME=$STAGING_HOME\""))
        XCTAssertTrue(
            script.contains(
                "BUILD_SHELL_HOME=\"${TATWO_STAGING_BUILD_HOME:-$HOME}\""))
        XCTAssertFalse(script.contains("\"HOME=$BUILD_SHELL_HOME\""))
        XCTAssertTrue(
            script.contains(
                "\"TATWO_ULTRAWORK_APP_SUPPORT=$APP_SUPPORT\"")
        )
        for requiredLaunchEnvironment in [
            "\"TATWO_MODEL_GATEWAY_URL=http://127.0.0.1:$GATEWAY_PORT\"",
            "\"TATWO_MODEL_GATEWAY_RESPONSES_URL=http://127.0.0.1:$GATEWAY_PORT/v1/responses\"",
            "\"TATWO_ULTRAWORK_CHAT_WORKDIR=$CHAT_WORKDIR\"",
            "\"TATWO_ULTRAWORK_APP_MCP_PORT=$APP_MCP_PORT\"",
            "\"TATWO_ULTRAWORK_PLG_ANCHOR_SERVICE=$ANCHOR_SERVICE\"",
            "\"TATWO_ULTRAWORK_PLG_ANCHOR_ACCOUNT=$ANCHOR_ACCOUNT\"",
            "\"TATWO_ULTRAWORK_PLG_ANCHOR_HELPER=$ANCHOR_HELPER_RELATIVE\"",
            "\"TATWO_ULTRAWORK_PLG_ANCHOR_HELPER_SHA256=$ANCHOR_HELPER_SHA256\"",
        ] {
            XCTAssertTrue(
                script.contains(requiredLaunchEnvironment),
                "sanitized staging launch must preserve \(requiredLaunchEnvironment)")
        }
        XCTAssertFalse(script.contains("/usr/bin/open -n"))
        XCTAssertFalse(script.contains("APP_SUPPORT=\"$STAGING_ROOT/app-support\""))
        XCTAssertTrue(script.contains("LSEnvironment"))
        XCTAssertTrue(script.contains("-name 'TatwoUltrawork_*.bundle'"))
        XCTAssertTrue(
            script.contains("TatwoUltrawork_TatwoUltraworkCore.bundle")
        )
        XCTAssertTrue(
            script.contains("TatwoUltrawork_TatwoUltraworkMac.bundle")
        )
        XCTAssertTrue(script.contains("COPIED_RESOURCE_BUNDLES"))
        XCTAssertTrue(
            script.contains("status --porcelain=v1 --untracked-files=all")
        )
        XCTAssertTrue(script.contains("\"sourceDirty\""))
        XCTAssertFalse(
            script.contains(
                "ai.tatwo.ultrawork.plg-chain-anchor.staging.20260716"))
    }

    func testStagingBuilderPinsFinalPostDeepSignedHelperBytes() throws {
        let script = try readSource("script/build_staging_app.sh")
        let deepSign = try XCTUnwrap(
            script.range(
                of: """
                codesign --force --deep --timestamp=none \\
                  --sign "$SIGNING_IDENTITY_SHA1" "$APP_BUNDLE"
                """))
        let postDeep = String(script[deepSign.upperBound...])

        XCTAssertTrue(postDeep.contains("ANCHOR_HELPER_SHA256=\"$("))
        XCTAssertTrue(
            postDeep.contains(
                "plutil -replace TatwoPLGAnchorHelperSHA256"))
        XCTAssertTrue(
            postDeep.contains(
                "LSEnvironment.TATWO_ULTRAWORK_PLG_ANCHOR_HELPER_SHA256"))
        XCTAssertTrue(
            postDeep.contains(
                """
                codesign --force --timestamp=none \\
                  --sign "$SIGNING_IDENTITY_SHA1" "$APP_BUNDLE"
                """))
        XCTAssertTrue(postDeep.contains("FINAL_ANCHOR_HELPER_SHA256"))
        XCTAssertTrue(postDeep.contains("helper hash changed after final signing"))
    }

    func testAnchorHelperUsesBuildScopedIdentityAndFailsClosedWithoutAuthUI() throws {
        let source = try readSource("Tools/TatwoPLGAnchorHelper/main.c")

        XCTAssertTrue(
            source.contains("TATWO_ULTRAWORK_PLG_ANCHOR_SERVICE"))
        XCTAssertTrue(
            source.contains("TATWO_ULTRAWORK_PLG_ANCHOR_ACCOUNT"))
        XCTAssertTrue(source.contains("kSecUseAuthenticationUI"))
        XCTAssertTrue(source.contains("kSecUseAuthenticationUIFail"))
    }

    func testProductionBuilderRequiresDeveloperIDAndPinsTheSignedAnchorHelper() throws {
        let script = try readSource("script/build_production_app.sh")

        XCTAssertTrue(script.contains("TATWO_DEVELOPER_ID_APPLICATION"))
        XCTAssertTrue(script.contains("Developer ID Application:"))
        XCTAssertTrue(script.contains("--options runtime"))
        XCTAssertTrue(script.contains("--timestamp"))
        XCTAssertTrue(script.contains("anchor apple generic"))
        XCTAssertTrue(script.contains("TatwoPLGAnchorHelper"))
        XCTAssertTrue(script.contains("Tools/TatwoPLGAnchorHelper/main.c"))
        XCTAssertTrue(script.contains("HELPER_CDHASH"))
        XCTAssertTrue(script.contains("HELPER_SHA256"))
        XCTAssertTrue(script.contains("TatwoPLGAnchorHelperSHA256"))
        XCTAssertTrue(script.contains("ai.tatwo.ultrawork.plg-chain-anchor.production.v3"))
        XCTAssertTrue(script.contains("stable-helper-v1"))
        XCTAssertTrue(script.contains("TATWO_ULTRAWORK_PLG_ANCHOR_SERVICE"))
        XCTAssertTrue(script.contains("TATWO_ULTRAWORK_PLG_ANCHOR_ACCOUNT"))
        XCTAssertTrue(script.contains("TATWO_ULTRAWORK_PLG_ANCHOR_HELPER"))
        XCTAssertTrue(script.contains("tatwo_codesign_embedded_sparkle"))
        XCTAssertTrue(script.contains("codesign --verify --deep --strict"))
        XCTAssertTrue(script.contains("TatwoSourceCommit"))
        XCTAssertTrue(script.contains("TatwoSourceTree"))
        XCTAssertTrue(script.contains("TatwoBuildClass"))
        XCTAssertTrue(script.contains("TatwoDistributionReady"))
        XCTAssertTrue(script.contains("TatwoAutomaticUpdatesEnabled"))
        XCTAssertTrue(script.contains("TATWO_ULTRAWORK_APP_MCP_PORT"))
        XCTAssertTrue(
            script.contains("schema=TatwoProductionIntentBuildReceiptV1\n")
        )
        XCTAssertTrue(script.contains("source_commit=$SOURCE_COMMIT"))
        XCTAssertTrue(script.contains("source_tree=$SOURCE_TREE"))
        XCTAssertTrue(script.contains("build_class=production-intent\n"))
        XCTAssertTrue(script.contains("distribution_ready=false\n"))
        XCTAssertTrue(script.contains("automatic_updates_enabled=false\n"))
        XCTAssertTrue(
            script.contains(
                "<key>TatwoAutomaticUpdatesEnabled</key><false/>")
        )
        XCTAssertTrue(
            script.contains(
                "<key>TatwoBuildClass</key><string>production-intent</string>")
        )
        XCTAssertTrue(
            script.contains("<key>TatwoDistributionReady</key><false/>")
        )
        XCTAssertFalse(script.contains("TatwoProductionBuildReceiptV1"))
        XCTAssertFalse(script.contains("build_class=production\n"))
        XCTAssertFalse(script.contains("distribution_ready=true\n"))
        XCTAssertFalse(script.contains("automatic_updates_enabled=true\n"))
        XCTAssertTrue(script.contains("helper_cdhash=$HELPER_CDHASH"))
        XCTAssertTrue(script.contains("helper_sha256=$HELPER_SHA256"))
        XCTAssertTrue(
            script.contains(
                "resource_bundle_count=$COPIED_RESOURCE_BUNDLES")
        )
        XCTAssertTrue(script.contains("--jobs \"$BUILD_JOBS\""))
        XCTAssertTrue(
            script.contains("TatwoUltrawork_TatwoUltraworkCore.bundle")
        )
        XCTAssertTrue(
            script.contains("TatwoUltrawork_TatwoUltraworkMac.bundle")
        )
    }

    func testPLGTransitionsRequireVerifiedAuthorityState() throws {
        let source = try chatPageSource
        let apply = try XCTUnwrap(
            source.slice(
                from: "private func applyPLG",
                through: "/// App 唯一可做的是向 Work OS chokepoint"))

        XCTAssertTrue(source.contains("enum PLGAuthorityState"))
        XCTAssertTrue(apply.contains("plgAuthorityState"))
        XCTAssertTrue(apply.contains("guard case .verified"))
        XCTAssertTrue(apply.contains("runID == run.id"))
    }

    func testPLGPlanningAdvanceMigratesLegacyProjectionAndKeepsFailureVisible() throws {
        let source = try chatPageSource
        let advance = try XCTUnwrap(
            source.slice(
                from: "func advancePLGFromPlanning()",
                through: "func endPLGRun()"))
        let apply = try XCTUnwrap(
            source.slice(
                from: "private func applyPLG",
                through: "/// App 唯一可做的是向 Work OS chokepoint"))

        XCTAssertTrue(advance.contains("migratePlanningProjection"))
        XCTAssertTrue(advance.contains("makePLGDomainProjection"))
        XCTAssertFalse(apply.contains("activePLGRun = nil"))
        XCTAssertTrue(apply.contains("plgError ="))
    }

    func testPLGQuarantineCannotBeClearedByAuthorizationRefresh() throws {
        let source = try chatPageSource
        let refresh = try XCTUnwrap(
            source.slice(
                from: "private func refreshPLGProjectionThroughWorkOSChokepoint",
                through: "func restoreActivePLGProjection"))

        XCTAssertTrue(source.contains("plgAuthorityState.isQuarantined"))
        XCTAssertTrue(refresh.contains("guard !plgAuthorityState.isQuarantined"))
    }

    func testPLGRelaunchDiscoversDurableChainWithoutCachedRunID() throws {
        let source = try chatPageSource
        let restore = try XCTUnwrap(
            source.slice(
                from: "func restoreActivePLGProjection",
                through: "private func persistActivePLGProjection"))
        let chainStore = try readSource(
            "Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/PLGChainStore.swift")

        XCTAssertTrue(chainStore.contains("func replayUnique("))
        XCTAssertTrue(chainStore.contains("case ambiguousChain"))
        XCTAssertTrue(restore.contains("preferredRunID: projection?.id"))
        XCTAssertTrue(restore.contains("thread.workOSContractID"))
        XCTAssertTrue(restore.contains("thread.workOSGoalID"))
    }

    func testLegacyLoopsBridgeCannotSpawnCodexOrBypassPLGContract() throws {
        let source = try chatPageSource
        let bridge = try XCTUnwrap(
            source.slice(
                from: "/// #16 主 chat → loops 橋",
                through: "func archiveSelectedThread"))

        XCTAssertFalse(bridge.contains("codex exec"))
        XCTAssertFalse(bridge.contains("dispatchLoopSubImpl"))
        XCTAssertTrue(bridge.contains("startPLGRun"))
        XCTAssertFalse(source.contains("丟進 loops 給 sol 做"))
    }

    func testPackagedGatewayAdapterHasNoWorkspaceFallback() throws {
        let source = try chatPageSource
        let resolver = try XCTUnwrap(
            source.slice(
                from: "static func gatewayDirectAdapterScriptURL",
                through: "private static func claudeAttachmentMention"))

        XCTAssertTrue(resolver.contains("Bundle.module.url"))
        XCTAssertFalse(resolver.contains("workspaceCandidates"))
        XCTAssertFalse(resolver.contains("currentDirectoryPath"))
    }

    func testThreadObjectiveUsesFullCanonicalIdentityInsteadOfPrefixJoin() throws {
        let source = try chatPageSource
        let context = try XCTUnwrap(
            source.slice(
                from: "func selectedThreadWorkOSContext",
                through: "func refreshSelectedWorkOSState"))

        XCTAssertTrue(context.contains("TatwoObjectiveIdentity"))
        XCTAssertTrue(context.contains("objectiveHash"))
        XCTAssertTrue(context.contains("preview"))
        XCTAssertFalse(context.contains("String(hint.prefix(96))"))
        XCTAssertFalse(context.contains("String(storedUserRequest.prefix(96))"))
    }

    func testPLGAndLoopsSurfacesMeetErgonomicSourceContract() throws {
        let cardSource = try readSource(
            "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/PLGFlowCard.swift")
        let loopsSource = try readSource(
            "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/LoopsSessionRail.swift")

        XCTAssertTrue(cardSource.contains("TatwoOperationalBlockerDescriptor.parse"))
        XCTAssertTrue(cardSource.contains("blockerClass"))
        XCTAssertTrue(cardSource.contains("resetDisplay"))
        XCTAssertTrue(cardSource.contains("retryDisplay"))
        XCTAssertTrue(cardSource.contains("ViewThatFits(in: .horizontal)"))
        XCTAssertTrue(cardSource.contains("spineVertical"))

        XCTAssertTrue(cardSource.contains(#".frame(minWidth: 44, minHeight: 44)"#))
        XCTAssertTrue(cardSource.contains(#".frame(minHeight: 44)"#))
        XCTAssertTrue(cardSource.contains(#".accessibilityLabel(paused ? "繼續 PLG 目標" : "暫停 PLG 目標")"#))
        XCTAssertTrue(cardSource.contains(#".accessibilityLabel("關閉本機 PLG 流程卡")"#))

        XCTAssertTrue(loopsSource.contains(#".frame(minWidth: 44, minHeight: 44)"#))
        XCTAssertTrue(loopsSource.contains(#".frame(minHeight: 44)"#))
        XCTAssertTrue(loopsSource.contains(#".accessibilityLabel("儲存規劃筆記")"#))
        XCTAssertTrue(loopsSource.contains(#".accessibilityLabel("封存這條 Loops")"#))

        XCTAssertGreaterThanOrEqual(try minimumNumericFontSize(in: cardSource), 11)
        XCTAssertGreaterThanOrEqual(try minimumNumericFontSize(in: loopsSource), 11)
    }

    func testReleaseLoopsRowsCannotBeEnabledByDemoEnvironment() throws {
        let chatSource = try chatPageSource
        let rows = try XCTUnwrap(
            chatSource.slice(
                from: "var loopsLiveRows: [TatwoLoopsLiveRow]",
                through: "func createLoopsSessionForSelectedThread"))

        XCTAssertTrue(rows.contains("#if DEBUG"))
        XCTAssertTrue(rows.contains("#endif"))
        XCTAssertEqual(
            rows.components(separatedBy: "TATWO_ULTRAWORK_LOOPS_LIVE_DEMO").count - 1,
            1)
    }

    private func readSource(_ relativePath: String) throws -> String {
        try ChatPageSourceScanner.readRelative(relativePath, repoRoot: repoRoot)
    }

    private func minimumNumericFontSize(in source: String) throws -> Double {
        let regex = try NSRegularExpression(
            pattern: #"\.font\(\.system\(size:\s*([0-9]+(?:\.[0-9]+)?)"#)
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        let sizes = regex.matches(in: source, range: range).compactMap { match -> Double? in
            guard let capture = Range(match.range(at: 1), in: source) else {
                return nil
            }
            return Double(source[capture])
        }
        return try XCTUnwrap(sizes.min())
    }
}
