import Foundation
import TatwoUltraworkCore
import XCTest
@testable import TatwoUltraworkMac

final class ChatNativeSubscriptionRuntimeTests: XCTestCase {
    func testRuntimeLocatorUsesOnlyBundledHelper() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tatwo-subscription-locator-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appendingPathComponent(
            "Tatwo Ultrawork.app",
            isDirectory: true)
        let helper = bundle
            .appendingPathComponent("Contents/Helpers", isDirectory: true)
            .appendingPathComponent("TatwoSubscriptionRuntime")
        try FileManager.default.createDirectory(
            at: helper.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: helper)

        let located = ChatNativeSubscriptionRuntimeLocator(
            bundleURL: bundle,
            isExecutableFile: { $0 == helper.path })
            .resolve()

        XCTAssertEqual(located, helper)
        XCTAssertNil(
            ChatNativeSubscriptionRuntimeLocator(
                bundleURL: bundle,
                isExecutableFile: { _ in false })
                .resolve())
        XCTAssertNotEqual(
            located?.path,
            "/Applications/Codex.app/Contents/Resources/codex")
    }

    func testSubscriptionTransportUsesChatGPTAccountAndTatwoDynamicTools()
        async throws
    {
        let session = FakeSubscriptionAppServerSession(
            responses: [
                "initialize": #"{"codexHome":"/tmp/tatwo"}"#,
                "account/read":
                    #"{"account":{"type":"chatgpt","email":"owner@example.invalid","planType":"pro"},"requiresOpenaiAuth":true}"#,
                "account/rateLimits/read":
                    #"{"rateLimits":{"limitId":"codex","limitName":"Codex","planType":"pro","primary":{"usedPercent":25,"resetsAt":1800000000,"windowDurationMins":300},"secondary":{"usedPercent":40,"resetsAt":1800500000,"windowDurationMins":10080}},"rateLimitsByLimitId":null,"rateLimitResetCredits":{"availableCount":1,"credits":[{"id":"credit-1","status":"available","resetType":"codexRateLimits","grantedAt":1790000000,"expiresAt":1800600000}]}}"#,
                "model/list":
                    #"{"data":[{"model":"gpt-5.6-sol"},{"model":"opus-5"}]}"#,
                "thread/start":
                    #"{"thread":{"id":"thread-1"},"model":"gpt-5.6-sol","modelProvider":"openai","reasoningEffort":"high","approvalPolicy":"never","approvalsReviewer":"user","cwd":"/tmp/tatwo","sandbox":{"type":"readOnly"}}"#,
                "turn/start": #"{"turn":{"id":"turn-1","status":"inProgress","items":[]}}"#,
            ],
            messages: [
                #"{"id":"server-1","method":"item/tool/call","params":{"threadId":"thread-1","turnId":"turn-1","callId":"call-1","tool":"read_file","arguments":{"path":"Package.swift"}}}"#,
                #"{"method":"item/completed","params":{"threadId":"thread-1","turnId":"turn-1","item":{"type":"agentMessage","id":"message-1","text":"SUBSCRIPTION_NATIVE_OK","phase":"final_answer"}}}"#,
                #"{"method":"turn/completed","params":{"threadId":"thread-1","turn":{"id":"turn-1","status":"completed","items":[],"error":null}}}"#,
            ])
        let transport = ChatNativeOpenAISubscriptionModelTransport(
            modelID: "gpt-5.6-sol",
            effort: "high",
            workspaceRoot: "/tmp/project",
            scratchDirectoryURL: URL(fileURLWithPath: "/tmp/tatwo"),
            sessionFactory: { session })
        let tools = [
            TatwoNativeToolDefinition(
                name: "read_file",
                description: "Read one workspace file.",
                inputSchemaJSON:
                    #"{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}"#),
        ]

        let first = try await transport.respond(
            to: TatwoNativeModelRequest(
                input: [.userText("Read Package.swift.")],
                tools: tools,
                modelStep: 1))
        XCTAssertEqual(
            first,
            TatwoNativeModelTurn(
                response: .toolCalls([
                    TatwoNativeToolCall(
                        id: "call-1",
                        name: "read_file",
                        argumentsJSON: #"{"path":"Package.swift"}"#),
                ]),
                attestation: TatwoNativeModelAttestation(
                    modelID: "gpt-5.6-sol",
                    effort: "high")))

        let second = try await transport.respond(
            to: TatwoNativeModelRequest(
                input: [
                    .userText("Read Package.swift."),
                    .toolCall(TatwoNativeToolCall(
                        id: "call-1",
                        name: "read_file",
                        argumentsJSON: #"{"path":"Package.swift"}"#)),
                    .toolResult(TatwoNativeToolResult(
                        callID: "call-1",
                        output: "PACKAGE_CONTENT")),
                ],
                tools: tools,
                modelStep: 2))
        XCTAssertEqual(
            second,
            TatwoNativeModelTurn(
                response: .assistantText("SUBSCRIPTION_NATIVE_OK"),
                attestation: TatwoNativeModelAttestation(
                    modelID: "gpt-5.6-sol",
                    effort: "high")))

        let recordedThreadStart = await session.params(for: "thread/start")
        let threadStart = try decodeObject(
            XCTUnwrap(recordedThreadStart))
        XCTAssertEqual(
            (threadStart["dynamicTools"] as? [[String: Any]])?
                .compactMap { $0["name"] as? String },
            ["read_file"])
        XCTAssertEqual(threadStart["model"] as? String, "gpt-5.6-sol")
        XCTAssertEqual(threadStart["sandbox"] as? String, "read-only")
        XCTAssertEqual(threadStart["cwd"] as? String, "/tmp/project")
        XCTAssertNil(threadStart["apiKey"])
        XCTAssertNil(threadStart["accessToken"])
        let config = try XCTUnwrap(
            threadStart["config"] as? [String: Any])
        let features = try XCTUnwrap(
            config["features"] as? [String: Any])
        for feature in [
            "apps",
            "plugins",
            "remote_plugin",
            "shell_tool",
            "unified_exec",
            "code_mode_host",
            "computer_use",
            "browser_use",
            "multi_agent",
        ] {
            XCTAssertEqual(
                features[feature] as? Bool,
                false,
                "\(feature) must be disabled for TATWO-owned execution")
        }

        let recordedToolReply = await session.serverResponse(
            id: .string("server-1"))
        let toolReply = try decodeObject(
            XCTUnwrap(recordedToolReply))
        XCTAssertEqual(toolReply["success"] as? Bool, true)
        XCTAssertEqual(
            (toolReply["contentItems"] as? [[String: Any]])?.first?["text"]
                as? String,
            "PACKAGE_CONTENT")
    }

    func testSubscriptionTransportRequiresChatGPTLogin() async {
        let session = FakeSubscriptionAppServerSession(
            responses: [
                "initialize": #"{"codexHome":"/tmp/tatwo"}"#,
                "account/read":
                    #"{"account":null,"requiresOpenaiAuth":true}"#,
            ],
            messages: [])
        let transport = ChatNativeOpenAISubscriptionModelTransport(
            modelID: "gpt-5.6-sol",
            effort: "high",
            workspaceRoot: "/tmp/project",
            scratchDirectoryURL: URL(fileURLWithPath: "/tmp/tatwo"),
            sessionFactory: { session })

        do {
            _ = try await transport.respond(
                to: TatwoNativeModelRequest(
                    input: [.userText("inspect")],
                    tools: [],
                    modelStep: 1))
            XCTFail("missing subscription login must fail closed")
        } catch let error as ChatNativeSubscriptionRuntimeError {
            XCTAssertEqual(error, .subscriptionLoginRequired)
            XCTAssertEqual(
                error.nativeFailureCode,
                "subscription_login_required")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testAccountServiceCompletesBrowserSubscriptionLogin() async {
        let session = LoginSubscriptionAppServerSession()
        let openedURL = LockedURLCapture()
        let service = ChatNativeSubscriptionAccountService(
            sessionFactory: { session })

        let status = await service.login { url in
            openedURL.record(url)
            return true
        }

        XCTAssertEqual(
            openedURL.value?.absoluteString,
            "https://auth.openai.com/tatwo-test")
        XCTAssertEqual(
            status,
            .signedIn(planType: "pro"))
    }

    @MainActor
    func testOnboardingOpensSubscriptionLoginURLOnMainThread() async {
        let session = LoginSubscriptionAppServerSession()
        let openedOnMainThread = LockedBoolCapture()
        let model = ChatNativeOpenAISubscriptionOnboardingModel(
            accountService: ChatNativeSubscriptionAccountService(
                sessionFactory: { session }),
            openURL: { _ in
                openedOnMainThread.record(Thread.isMainThread)
                return true
            })

        await model.signIn()

        XCTAssertEqual(openedOnMainThread.value, true)
        XCTAssertEqual(model.status, .signedIn(planType: "pro"))
    }

    @MainActor
    func testOpenAIOnboardingQuotaAndTransportShareAccountServiceSource()
        async throws
    {
        let homeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tatwo-openai-single-source-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: homeURL) }
        let session = FakeSubscriptionAppServerSession(
            responses: [
                "initialize": #"{"codexHome":"/tmp/tatwo"}"#,
                "account/read":
                    #"{"account":{"type":"chatgpt","email":"owner@example.invalid","planType":"pro"},"requiresOpenaiAuth":true}"#,
                "account/rateLimits/read":
                    #"{"rateLimits":{"limitId":"codex","limitName":"Codex","planType":"pro","primary":{"usedPercent":25,"resetsAt":1800000000,"windowDurationMins":300},"secondary":{"usedPercent":40,"resetsAt":1800500000,"windowDurationMins":10080}},"rateLimitsByLimitId":null,"rateLimitResetCredits":{"availableCount":1,"credits":[{"id":"credit-1","status":"available","resetType":"codexRateLimits","grantedAt":1790000000,"expiresAt":1800600000}]}}"#,
                "model/list":
                    #"{"data":[{"model":"gpt-5.6-sol"}]}"#,
                "thread/start":
                    #"{"thread":{"id":"thread-1"},"model":"gpt-5.6-sol","modelProvider":"openai","reasoningEffort":"high","approvalPolicy":"never","approvalsReviewer":"user","cwd":"/tmp/project","sandbox":{"type":"readOnly"}}"#,
                "turn/start":
                    #"{"turn":{"id":"turn-1","status":"inProgress","items":[]}}"#,
            ],
            messages: [
                #"{"method":"item/completed","params":{"threadId":"thread-1","turnId":"turn-1","item":{"type":"agentMessage","id":"message-1","text":"OPENAI_SINGLE_SOURCE_OK","phase":"final_answer"}}}"#,
                #"{"method":"turn/completed","params":{"threadId":"thread-1","turn":{"id":"turn-1","status":"completed","items":[],"error":null}}}"#,
            ])
        let homeLocator = ChatNativeSubscriptionHomeLocator(
            environment: [
                "TATWO_NATIVE_SUBSCRIPTION_HOME": homeURL.path,
            ])
        let service = ChatNativeSubscriptionAccountService(
            homeLocator: homeLocator,
            sessionFactory: { session })
        let onboarding =
            ChatNativeOpenAISubscriptionOnboardingModel(
                accountService: service)

        await onboarding.refresh()
        let loadedQuota = await TatwoLiveQuotaReader.loadCodex(
            provider: testUsageProvider(
                id: "codex-gpt",
                displayName: "ChatGPT"),
            allowExternalAccess: true,
            accountSnapshotReader: {
                await service.quotaSnapshot()
            },
            homeURL: homeURL)
        let quota = try XCTUnwrap(loadedQuota)
        let transport = ChatNativeOpenAISubscriptionModelTransport(
            modelID: "gpt-5.6-sol",
            effort: "high",
            workspaceRoot: "/tmp/project",
            scratchDirectoryURL: homeURL
                .appendingPathComponent("transport-scratch"),
            homeLocator: homeLocator,
            sessionFactory: { session })
        let turn = try await transport.respond(
            to: TatwoNativeModelRequest(
                input: [.userText("Use the same account source.")],
                tools: [],
                modelStep: 1))

        XCTAssertEqual(
            onboarding.status,
            .signedIn(planType: "pro"))
        XCTAssertEqual(quota.status, .installed)
        XCTAssertEqual(quota.statusText, "live")
        XCTAssertEqual(quota.planLabel, "PRO")
        XCTAssertEqual(quota.primaryRemainingPercent, 75)
        XCTAssertEqual(quota.secondaryRemainingPercent, 60)
        XCTAssertEqual(quota.resetCreditsAvailable, 1)
        XCTAssertEqual(
            turn.response,
            .assistantText("OPENAI_SINGLE_SOURCE_OK"))
        let accountReadCount = await session.requestCount(
            for: "account/read")
        XCTAssertEqual(accountReadCount, 3)
        let rateLimitReadCount = await session.requestCount(
            for: "account/rateLimits/read")
        XCTAssertEqual(rateLimitReadCount, 1)
    }

    func testOpenAILoginHomeEqualsCodexChatHome() {
        let bundle = URL(fileURLWithPath: "/tmp/Tatwo Ultrawork.app")
        let codex = bundle.appendingPathComponent(
            "Contents/Helpers/TatwoSubscriptionRuntime").path
        let environment = [
            "PATH": "/usr/bin:/bin",
            "TATWO_NATIVE_SUBSCRIPTION_HOME":
                "/tmp/tatwo-openai-single-home",
        ]
        let loginHome = ChatNativeSubscriptionHomeLocator(
            environment: environment).resolve().path
        let plan = TatwoChatCommandPlanner.plan(
            mode: .chat,
            route: TatwoChatRouteProfile.resolve("gpt-5.6-sol"),
            turn: "hello",
            workingDirectoryPath: "/tmp/tatwo-work",
            permissionPreset: .approveForMe,
            effort: .high,
            gatewayDirectScriptPath:
                "/tmp/tatwo-direct-gateway-chat.mjs",
            codexHomePath: loginHome,
            bundleURL: bundle,
            environment: environment,
            isExecutableFile: { $0 == codex })

        XCTAssertEqual(plan.runtimeAdapter, .codexExec)
        XCTAssertEqual(plan.environmentOverrides["HOME"], loginHome)
        XCTAssertEqual(plan.environmentOverrides["CODEX_HOME"], loginHome)
    }

    func testOpenAIAccountServiceDistinguishesExpiredStoredLogin()
        async
    {
        let session = FakeSubscriptionAppServerSession(
            responses: [
                "initialize": #"{"codexHome":"/tmp/tatwo"}"#,
                "account/read":
                    #"{"account":null,"requiresOpenaiAuth":true}"#,
            ],
            messages: [])
        let service = ChatNativeSubscriptionAccountService(
            sessionFactory: { session },
            hasStoredCredentials: { true })

        let status = await service.status()

        XCTAssertEqual(status, .requiresReauthentication)
    }

    func testOpenAIQuotaUsesAccountServiceReauthenticationTruth()
        async throws
    {
        let loadedRow = await TatwoLiveQuotaReader.loadCodex(
            provider: testUsageProvider(
                id: "codex-gpt",
                displayName: "ChatGPT"),
            allowExternalAccess: true,
            accountSnapshotReader: {
                ChatNativeSubscriptionAccountSnapshot(
                    status: .requiresReauthentication,
                    rateLimits: nil)
            },
            homeURL: URL(
                fileURLWithPath: "/tmp/tatwo-openai-expired",
                isDirectory: true))
        let row = try XCTUnwrap(loadedRow)

        XCTAssertEqual(row.status, .missing)
        XCTAssertEqual(row.statusText, "需重新登入")
        XCTAssertTrue(row.caption.contains("已到期"))
        XCTAssertNil(row.remainingPercent)
    }

    func testOpenAIQuotaRefreshSurfacesRateLimitParsingFailure()
        async throws
    {
        let session = FakeSubscriptionAppServerSession(
            responses: [
                "initialize": #"{"codexHome":"/tmp/tatwo"}"#,
                "account/read":
                    #"{"account":{"type":"chatgpt","planType":"pro"}}"#,
                "account/rateLimits/read": #"{}"#,
            ],
            messages: [])
        let service = ChatNativeSubscriptionAccountService(
            sessionFactory: { session })

        let snapshot = await service.quotaSnapshot()
        let loadedRow = await TatwoLiveQuotaReader.loadCodex(
            provider: testUsageProvider(
                id: "codex-gpt",
                displayName: "ChatGPT"),
            allowExternalAccess: true,
            accountSnapshotReader: { snapshot },
            homeURL: URL(
                fileURLWithPath: "/tmp/tatwo-openai-quota-failure",
                isDirectory: true))
        let row = try XCTUnwrap(loadedRow)

        XCTAssertEqual(
            snapshot.status,
            .signedIn(planType: "pro"))
        XCTAssertNil(snapshot.rateLimits)
        XCTAssertEqual(snapshot.rateLimitFailure, .parsing)
        XCTAssertEqual(row.status, .installed)
        XCTAssertEqual(row.statusText, "已登入")
        XCTAssertEqual(row.sourceBadge, "失敗")
        XCTAssertTrue(row.caption.contains("回應解析失敗"))
        XCTAssertNil(row.primaryRemainingPercent)
        let rateLimitReadCount = await session.requestCount(
            for: "account/rateLimits/read")
        XCTAssertEqual(rateLimitReadCount, 1)
    }

    @MainActor
    func testSubscriptionBrowserLauncherFallsBackToSafari()
    {
        let authorizationURL = URL(
            string: "https://auth.x.ai/oauth2/authorize?state=test")!
        let safariURL = URL(
            fileURLWithPath:
                "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app",
            isDirectory: true)
        var openedApplicationURL: URL?
        var openedAuthorizationURL: URL?

        let opened = ChatNativeSubscriptionBrowserLauncher.open(
            authorizationURL,
            defaultOpen: { _ in false },
            safariApplicationURL: { safariURL },
            openWithApplication: { applicationURL, targetURL in
                openedApplicationURL = applicationURL
                openedAuthorizationURL = targetURL
                return true
            })

        XCTAssertTrue(opened)
        XCTAssertEqual(openedApplicationURL, safariURL)
        XCTAssertEqual(openedAuthorizationURL, authorizationURL)
    }

    func testProductionCompositionUsesSubscriptionForExactNativeModels()
        throws
    {
        let appRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let runtime = try ChatSourceFamily.read("ChatRuntime.swift")
        let settings = try String(
            contentsOf: appRoot.appendingPathComponent(
                "Sources/TatwoUltraworkMac/ChatPageSettings.swift"),
            encoding: .utf8)

        XCTAssertTrue(runtime.contains(
            "ChatNativeOpenAISubscriptionModelTransport"))
        XCTAssertTrue(runtime.contains(
            "ChatNativeClaudeSubscriptionModelTransport"))
        XCTAssertTrue(runtime.contains(
            "ChatNativeGrokSubscriptionModelTransport"))
        XCTAssertFalse(runtime.contains(
            "TatwoNativeDirectResponsesTransport("))
        XCTAssertFalse(runtime.contains(
            "TatwoNativeAnthropicMessagesTransport("))
        XCTAssertFalse(runtime.contains(
            "ChatNativeSolKeychainCredentialBroker()"))
        XCTAssertFalse(runtime.contains(
            "ChatNativeOpusKeychainCredentialBroker()"))
        XCTAssertTrue(settings.contains(
            "ChatNativeOpenAISubscriptionOnboardingView()"))
        XCTAssertTrue(settings.contains(
            "ChatNativeClaudeSubscriptionOnboardingView()"))
        XCTAssertTrue(settings.contains(
            "ChatNativeGrokSubscriptionOnboardingView()"))
        XCTAssertFalse(settings.contains(
            "ChatNativeSolCredentialOnboardingView()"))
        XCTAssertFalse(settings.contains(
            "ChatNativeOpusCredentialOnboardingView()"))
    }

    func testProductionSourceContainsNoDirectAPICredentialRoute() {
        let appRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let repoRoot = appRoot
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let forbiddenPaths = [
            appRoot.appendingPathComponent(
                "Sources/TatwoUltraworkMac/ChatNativeSolCredential.swift"),
            appRoot.appendingPathComponent(
                "Sources/TatwoUltraworkMac/ChatNativeSolCredentialOnboarding.swift"),
            appRoot.appendingPathComponent(
                "Sources/TatwoUltraworkMac/ChatNativeOpusCredential.swift"),
            appRoot.appendingPathComponent(
                "Sources/TatwoUltraworkMac/ChatNativeOpusCredentialOnboarding.swift"),
            repoRoot.appendingPathComponent(
                "Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/TatwoNativeDirectResponsesTransport.swift"),
            repoRoot.appendingPathComponent(
                "Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/TatwoNativeAnthropicMessagesTransport.swift"),
        ]

        for path in forbiddenPaths {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: path.path),
                "Direct API route must not ship: \(path.lastPathComponent)")
        }
    }

    func testStagingBuilderBundlesPinnedSubscriptionRuntime() throws {
        let appRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let repoRoot = appRoot
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        // M1 之後三家 runtime 的解析/打包邏輯住在共用腳本
        // scripts/tatwo-stage-model-runtimes.sh，staging 與正式 installer
        // 都 source 它；本測試改對「兩檔合併原文」斷言，並要求 staging
        // 腳本確實引用共用腳本。
        let stagingScript = try String(
            contentsOf: repoRoot.appendingPathComponent(
                "script/build_staging_app.sh"),
            encoding: .utf8)
        let sharedScript = try String(
            contentsOf: repoRoot.appendingPathComponent(
                "scripts/tatwo-stage-model-runtimes.sh"),
            encoding: .utf8)
        XCTAssertTrue(stagingScript.contains(
            "scripts/tatwo-stage-model-runtimes.sh"))
        let script = stagingScript + "\n" + sharedScript

        XCTAssertTrue(script.contains(
            "TATWO_SUBSCRIPTION_RUNTIME_SOURCE"))
        XCTAssertTrue(script.contains(
            "Contents/Helpers/TatwoSubscriptionRuntime"))
        XCTAssertTrue(script.contains(
            "TATWO_SUBSCRIPTION_CODE_MODE_HOST_SOURCE"))
        XCTAssertTrue(script.contains(
            "Contents/Helpers/codex-code-mode-host"))
        XCTAssertTrue(script.contains(
            "TATWO_NATIVE_SUBSCRIPTION_HOME"))
        XCTAssertTrue(script.contains(
            "\"subscriptionRuntimeSHA256\""))
        XCTAssertTrue(script.contains(
            "\"subscriptionCodeModeHostSHA256\""))
        XCTAssertTrue(script.contains(
            "\"subscriptionRuntimeVersion\""))
        XCTAssertTrue(script.contains(
            "\"subscriptionThirdPartyNotices\""))
        XCTAssertTrue(script.contains(
            "TATWO_CLAUDE_SUBSCRIPTION_RUNTIME_SOURCE"))
        XCTAssertTrue(script.contains(
            "Contents/Helpers/TatwoClaudeSubscriptionRuntime"))
        XCTAssertTrue(script.contains(
            "TATWO_NATIVE_CLAUDE_SUBSCRIPTION_HOME"))
        XCTAssertTrue(script.contains(
            "\"claudeSubscriptionRuntimeSHA256\""))
        XCTAssertTrue(script.contains(
            "\"claudeSubscriptionRuntimeVersion\""))
        XCTAssertTrue(script.contains(
            "\"claudeSubscriptionLicense\""))
        XCTAssertTrue(script.contains(
            "TATWO_GROK_SUBSCRIPTION_RUNTIME_SOURCE"))
        XCTAssertTrue(script.contains(
            "Contents/Helpers/TatwoGrokSubscriptionRuntime"))
        XCTAssertTrue(script.contains(
            "Contents/Helpers/TatwoGrokVendorRuntime"))
        XCTAssertTrue(script.contains(
            "TATWO_NATIVE_GROK_SUBSCRIPTION_HOME"))
        XCTAssertTrue(script.contains(
            "\"grokSubscriptionRuntimeSHA256\""))
        XCTAssertTrue(script.contains(
            "\"grokSubscriptionRuntimeVersion\""))
    }

    func testOpenAITransportDoesNotClaimOpus() {
        XCTAssertEqual(
            ChatNativeOpenAISubscriptionModelTransport.supportedModelIDs,
            ["gpt-5.6-sol"])
        XCTAssertFalse(
            ChatNativeOpenAISubscriptionModelTransport.supportedModelIDs
                .contains("opus-5"))
    }

    func testSubscriptionRuntimeEnvironmentIsolatedFromParentCodexAndGateways() {
        let homeURL = URL(
            fileURLWithPath: "/tmp/tatwo-subscription-home",
            isDirectory: true)
        let scrubbed =
            ChatNativeSubscriptionEnvironment.isolatedProcessEnvironment(
                inheriting: [
            "HOME": "/tmp/old-home",
            "PATH": "/usr/bin:/bin",
            "TMPDIR": "/tmp/",
            "LANG": "zh_TW.UTF-8",
            "CODEX_HOME": "/tmp/parent-codex-home",
            "CODEX_THREAD_ID": "parent-thread",
            "CODEX_PERMISSION_PROFILE": ":danger-full-access",
            "CODEX_INTERNAL_ORIGINATOR_OVERRIDE": "codex_app",
            "CODEX_MODEL_GATEWAY_URL": "http://127.0.0.1:9999",
            "TATWO_ULTRAWORK_APP_MCP_PORT": "49152",
            "TATWO_MODEL_GATEWAY_URL": "http://127.0.0.1:9998",
            "OPENAI_API_KEY": "forbidden",
            "ANTHROPIC_API_KEY": "forbidden",
            "ANTHROPIC_AUTH_TOKEN": "forbidden",
            "CLAUDE_CODE_OAUTH_TOKEN": "forbidden",
            "CODEX_ACCESS_TOKEN": "forbidden",
            "GROK_API_KEY": "forbidden",
            "MINIMAX_API_KEY": "forbidden",
            "GOOGLE_API_KEY": "forbidden",
            "GEMINI_API_KEY": "forbidden",
            "XAI_API_KEY": "forbidden",
                ],
                homeURL: homeURL)

        XCTAssertEqual(scrubbed["PATH"], "/usr/bin:/bin")
        XCTAssertEqual(scrubbed["TMPDIR"], "/tmp/")
        XCTAssertEqual(scrubbed["LANG"], "zh_TW.UTF-8")
        XCTAssertEqual(scrubbed["HOME"], homeURL.path)
        XCTAssertEqual(scrubbed["CODEX_HOME"], homeURL.path)
        XCTAssertNil(scrubbed["CODEX_THREAD_ID"])
        XCTAssertNil(scrubbed["CODEX_PERMISSION_PROFILE"])
        XCTAssertNil(scrubbed["CODEX_INTERNAL_ORIGINATOR_OVERRIDE"])
        XCTAssertNil(scrubbed["CODEX_MODEL_GATEWAY_URL"])
        XCTAssertNil(scrubbed["TATWO_ULTRAWORK_APP_MCP_PORT"])
        XCTAssertNil(scrubbed["TATWO_MODEL_GATEWAY_URL"])
        XCTAssertNil(scrubbed["OPENAI_API_KEY"])
        XCTAssertNil(scrubbed["ANTHROPIC_API_KEY"])
        XCTAssertNil(scrubbed["ANTHROPIC_AUTH_TOKEN"])
        XCTAssertNil(scrubbed["CLAUDE_CODE_OAUTH_TOKEN"])
        XCTAssertNil(scrubbed["CODEX_ACCESS_TOKEN"])
        XCTAssertNil(scrubbed["GROK_API_KEY"])
        XCTAssertNil(scrubbed["MINIMAX_API_KEY"])
        XCTAssertNil(scrubbed["GOOGLE_API_KEY"])
        XCTAssertNil(scrubbed["GEMINI_API_KEY"])
        XCTAssertNil(scrubbed["XAI_API_KEY"])
    }

    func testSubscriptionRuntimeDisablesExternalToolSources() {
        XCTAssertEqual(
            ChatNativeSubscriptionProcessSession.runtimeArguments,
            [
                "app-server",
                "--stdio",
                "--disable",
                "apps",
                "--disable",
                "plugins",
                "--disable",
                "remote_plugin",
                "--disable",
                "shell_tool",
                "--disable",
                "unified_exec",
                "--disable",
                "code_mode_host",
                "--disable",
                "computer_use",
                "--disable",
                "browser_use",
                "--disable",
                "multi_agent",
            ])
    }

    func testOnboardingSeparatesChatGPTClaudeAndGrokSubscriptionLogin()
        throws
    {
        let appRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let onboarding = try String(
            contentsOf: appRoot.appendingPathComponent(
                "Sources/TatwoUltraworkMac/ChatNativeSubscriptionOnboarding.swift"),
            encoding: .utf8)

        XCTAssertTrue(onboarding.contains("ChatGPT 訂閱登入"))
        XCTAssertTrue(onboarding.contains("Claude 訂閱登入"))
        XCTAssertTrue(onboarding.contains("Grok 訂閱登入"))
        XCTAssertTrue(onboarding.contains("claude auth login --claudeai"))
        XCTAssertTrue(onboarding.contains("Grok OAuth 訂閱流程"))
        XCTAssertFalse(onboarding.contains("Sol 與 Opus 共用"))
        XCTAssertFalse(onboarding.contains("--console"))
    }

    func testQuotaDeckUsesSubscriptionAccountServicesAsAuthTruth()
        throws
    {
        let appRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let quotaSource = try String(
            contentsOf: appRoot.appendingPathComponent(
                "Sources/TatwoUltraworkMac/TatwoM3PrototypeViews.swift"),
            encoding: .utf8)

        XCTAssertTrue(
            quotaSource.contains(
                "ChatNativeSubscriptionAccountService()"))
        XCTAssertTrue(
            quotaSource.contains(
                "ChatNativeClaudeSubscriptionAccountService()"))
        XCTAssertTrue(quotaSource.contains(".quotaSnapshot()"))
        XCTAssertFalse(quotaSource.contains("ClaudeCLIStatusReader"))
        XCTAssertFalse(
            quotaSource.contains("/opt/homebrew/bin/claude"))
        XCTAssertFalse(
            quotaSource.contains("/usr/local/bin/claude"))
        XCTAssertFalse(quotaSource.contains("CodexV3ImportStore"))
    }

    func testClaudeAccountServiceUsesNativeUserProfileForSubscriptionLogin()
        async
    {
        let runner = FakeClaudeSubscriptionProcessRunner(
            results: [
                ChatNativeClaudeProcessResult(
                    exitCode: 0,
                    stdout: Data(
                        #"{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","subscriptionType":"max"}"#
                            .utf8),
                    stderr: Data()),
            ])
        let service = ChatNativeClaudeSubscriptionAccountService(
            homeLocator: ChatNativeClaudeSubscriptionHomeLocator(
                environment: [
                    "TATWO_NATIVE_CLAUDE_SUBSCRIPTION_HOME":
                        "/tmp/tatwo-claude-state",
                ]),
            profileHomeURL: URL(
                fileURLWithPath: "/Users/example",
                isDirectory: true),
            runnerFactory: { runner })

        let status = await service.status()

        XCTAssertEqual(status, .signedIn(subscriptionType: "max"))
        let invocation = await runner.invocations.first
        XCTAssertEqual(invocation?.environment["HOME"], "/Users/example")
        XCTAssertNil(invocation?.environment["CLAUDE_CONFIG_DIR"])
        XCTAssertNil(
            invocation?.environment["CLAUDE_SECURESTORAGE_CONFIG_DIR"])
        XCTAssertEqual(
            invocation?.currentDirectoryURL.path,
            "/tmp/tatwo-claude-state/login-sessions")
    }

    @MainActor
    func testClaudeOnboardingQuotaAndTransportShareAccountServiceSource()
        async throws
    {
        let statusJSON = Data(
            #"{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","subscriptionType":"max"}"#
                .utf8)
        let runner = FakeClaudeSubscriptionProcessRunner(
            results: [
                ChatNativeClaudeProcessResult(
                    exitCode: 0,
                    stdout: statusJSON,
                    stderr: Data()),
                ChatNativeClaudeProcessResult(
                    exitCode: 0,
                    stdout: statusJSON,
                    stderr: Data()),
                ChatNativeClaudeProcessResult(
                    exitCode: 0,
                    stdout: statusJSON,
                    stderr: Data()),
                ChatNativeClaudeProcessResult(
                    exitCode: 0,
                    stdout: Data(
                        #"{"is_error":false,"subtype":"success","modelUsage":{"claude-opus-5":{"canonicalModel":"claude-opus-5","provider":"firstParty","outputTokens":64}},"structured_output":{"kind":"assistant_text","text":"CLAUDE_SINGLE_SOURCE_OK"}}"#
                            .utf8),
                    stderr: Data()),
            ])
        let subscriptionHome = URL(
            fileURLWithPath: "/tmp/tatwo-claude-single-source",
            isDirectory: true)
        let profileHome = URL(
            fileURLWithPath: "/Users/example",
            isDirectory: true)
        let homeLocator = ChatNativeClaudeSubscriptionHomeLocator(
            environment: [
                "TATWO_NATIVE_CLAUDE_SUBSCRIPTION_HOME":
                    subscriptionHome.path,
            ])
        let service = ChatNativeClaudeSubscriptionAccountService(
            homeLocator: homeLocator,
            profileHomeURL: profileHome,
            runnerFactory: { runner })
        let onboarding =
            ChatNativeClaudeSubscriptionOnboardingModel(
                accountService: service)

        await onboarding.refresh()
        let loadedQuota = await TatwoLiveQuotaReader.loadClaude(
            provider: testUsageProvider(
                id: "claude",
                displayName: "Claude"),
            accountStatusReader: {
                await service.status()
            },
            usageClient: FixedClaudeOAuthUsageClient())
        let quota = try XCTUnwrap(loadedQuota)
        let transport = ChatNativeClaudeSubscriptionModelTransport(
            modelID: "opus-5",
            effort: "high",
            workspaceRoot: "/tmp/project",
            scratchDirectoryURL: subscriptionHome
                .appendingPathComponent("transport-scratch"),
            homeLocator: homeLocator,
            profileHomeURL: profileHome,
            runnerFactory: { runner })
        let turn = try await transport.respond(
            to: TatwoNativeModelRequest(
                input: [.userText("Use the same account source.")],
                tools: [],
                modelStep: 1))

        XCTAssertEqual(
            onboarding.status,
            .signedIn(subscriptionType: "max"))
        XCTAssertEqual(quota.status, .installed)
        XCTAssertEqual(quota.statusText, "live")
        XCTAssertEqual(quota.planLabel, "MAX")
        XCTAssertEqual(
            turn.response,
            .assistantText("CLAUDE_SINGLE_SOURCE_OK"))

        let invocations = await runner.invocations
        XCTAssertEqual(
            invocations.prefix(3).map(\.arguments),
            Array(repeating: ["auth", "status", "--json"], count: 3))
        XCTAssertEqual(
            invocations[0].currentDirectoryURL,
            subscriptionHome.appendingPathComponent(
                "login-sessions",
                isDirectory: true))
        XCTAssertEqual(
            invocations[1].currentDirectoryURL,
            subscriptionHome.appendingPathComponent(
                "login-sessions",
                isDirectory: true))
        XCTAssertEqual(
            invocations[2].currentDirectoryURL,
            subscriptionHome.appendingPathComponent(
                "transport-scratch"))
        XCTAssertTrue(
            invocations.allSatisfy {
                $0.environment["HOME"] == profileHome.path
            })
    }

    func testClaudeTransportUsesClaudeAIOnlyAndAttestsExactOpusHigh()
        async throws
    {
        let runner = FakeClaudeSubscriptionProcessRunner(
            results: [
                ChatNativeClaudeProcessResult(
                    exitCode: 0,
                    stdout: Data(
                        #"{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","subscriptionType":"max"}"#
                            .utf8),
                    stderr: Data()),
                ChatNativeClaudeProcessResult(
                    exitCode: 0,
                    stdout: Data(
                        #"{"is_error":false,"subtype":"success","modelUsage":{"claude-opus-5":{"canonicalModel":"claude-opus-5","provider":"firstParty","outputTokens":64}},"structured_output":{"kind":"assistant_text","text":"CLAUDE_SUBSCRIPTION_OK"}}"#
                            .utf8),
                    stderr: Data()),
            ])
        let transport = ChatNativeClaudeSubscriptionModelTransport(
            modelID: "opus-5",
            effort: "high",
            workspaceRoot: "/tmp/project",
            scratchDirectoryURL: URL(
                fileURLWithPath: "/tmp/tatwo-claude-test"),
            homeLocator: ChatNativeClaudeSubscriptionHomeLocator(
                environment: [
                    "TATWO_NATIVE_CLAUDE_SUBSCRIPTION_HOME":
                        "/tmp/tatwo-claude-home",
                ]),
            profileHomeURL: URL(
                fileURLWithPath: "/Users/example",
                isDirectory: true),
            runnerFactory: { runner })

        let turn = try await transport.respond(
            to: TatwoNativeModelRequest(
                input: [.userText("Inspect the project.")],
                tools: [],
                modelStep: 1))

        XCTAssertEqual(
            turn,
            TatwoNativeModelTurn(
                response: .assistantText("CLAUDE_SUBSCRIPTION_OK"),
                attestation: TatwoNativeModelAttestation(
                    modelID: "opus-5",
                    effort: "high",
                    fallbackCount: 0)))

        let invocations = await runner.invocations
        XCTAssertEqual(
            invocations.first?.arguments,
            ["auth", "status", "--json"])
        let modelArguments = try XCTUnwrap(invocations.last?.arguments)
        XCTAssertTrue(modelArguments.contains("claude-opus-5"))
        XCTAssertTrue(modelArguments.contains("high"))
        XCTAssertTrue(modelArguments.contains("--safe-mode"))
        XCTAssertTrue(modelArguments.contains("--tools"))
        XCTAssertFalse(modelArguments.contains("--fallback-model"))
        XCTAssertFalse(modelArguments.contains("--console"))
        XCTAssertEqual(
            invocations.last?.environment["HOME"],
            "/Users/example")
        XCTAssertNil(invocations.last?.environment["CLAUDE_CONFIG_DIR"])
        XCTAssertNil(
            invocations.last?.environment[
                "CLAUDE_SECURESTORAGE_CONFIG_DIR"])
        for key in ChatNativeSubscriptionEnvironment
            .forbiddenCredentialKeys
        {
            XCTAssertNil(invocations.last?.environment[key])
        }
    }

    func testClaudeTransportForwardsMediumEffortForNormalOpusWork()
        async throws
    {
        let runner = FakeClaudeSubscriptionProcessRunner(
            results: [
                ChatNativeClaudeProcessResult(
                    exitCode: 0,
                    stdout: Data(
                        #"{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","subscriptionType":"max"}"#
                            .utf8),
                    stderr: Data()),
                ChatNativeClaudeProcessResult(
                    exitCode: 0,
                    stdout: Data(
                        #"{"is_error":false,"subtype":"success","modelUsage":{"claude-opus-5":{"canonicalModel":"claude-opus-5","provider":"firstParty","outputTokens":64}},"structured_output":{"kind":"assistant_text","text":"CLAUDE_MEDIUM_OK"}}"#
                            .utf8),
                    stderr: Data()),
            ])
        let transport = ChatNativeClaudeSubscriptionModelTransport(
            modelID: "opus-5",
            effort: "medium",
            workspaceRoot: "/tmp/project",
            scratchDirectoryURL: URL(
                fileURLWithPath: "/tmp/tatwo-claude-medium-test"),
            profileHomeURL: URL(
                fileURLWithPath: "/Users/example",
                isDirectory: true),
            runnerFactory: { runner })

        let turn = try await transport.respond(
            to: TatwoNativeModelRequest(
                input: [.userText("Review the bounded repair.")],
                tools: [],
                modelStep: 1))

        XCTAssertEqual(
            turn.attestation,
            TatwoNativeModelAttestation(
                modelID: "opus-5",
                effort: "medium",
                fallbackCount: 0))
        let invocations = await runner.invocations
        let modelArguments = try XCTUnwrap(
            invocations.last?.arguments)
        XCTAssertEqual(
            argumentValue(after: "--effort", in: modelArguments),
            "medium")
    }

    func testClaudeTransportUsesExactFableSubscriptionRouteAtMediumEffort()
        async throws
    {
        let runner = FakeClaudeSubscriptionProcessRunner(
            results: [
                ChatNativeClaudeProcessResult(
                    exitCode: 0,
                    stdout: Data(
                        #"{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","subscriptionType":"max"}"#
                            .utf8),
                    stderr: Data()),
                ChatNativeClaudeProcessResult(
                    exitCode: 0,
                    stdout: Data(
                        #"{"is_error":false,"subtype":"success","modelUsage":{"claude-fable-5":{"canonicalModel":"claude-fable-5","provider":"firstParty","outputTokens":64}},"structured_output":{"kind":"assistant_text","text":"FABLE_NATIVE_OK"}}"#
                            .utf8),
                    stderr: Data()),
            ])
        let transport = ChatNativeClaudeSubscriptionModelTransport(
            modelID: "fable-5",
            effort: "medium",
            workspaceRoot: "/tmp/project",
            scratchDirectoryURL: URL(
                fileURLWithPath: "/tmp/tatwo-fable-native-test"),
            profileHomeURL: URL(
                fileURLWithPath: "/Users/example",
                isDirectory: true),
            runnerFactory: { runner })

        let turn = try await transport.respond(
            to: TatwoNativeModelRequest(
                input: [.userText("Plan the bounded Island cleanup.")],
                tools: [],
                modelStep: 1))

        XCTAssertEqual(
            turn,
            TatwoNativeModelTurn(
                response: .assistantText("FABLE_NATIVE_OK"),
                attestation: TatwoNativeModelAttestation(
                    modelID: "fable-5",
                    effort: "medium",
                    fallbackCount: 0)))
        let recordedInvocations = await runner.invocations
        let invocation = try XCTUnwrap(recordedInvocations.last)
        XCTAssertEqual(
            argumentValue(after: "--model", in: invocation.arguments),
            "claude-fable-5")
        XCTAssertEqual(
            argumentValue(after: "--effort", in: invocation.arguments),
            "medium")
        XCTAssertTrue(
            String(decoding: invocation.standardInput ?? Data(), as: UTF8.self)
                .contains("exact Claude Fable 5 execution engine"))
    }

    func testClaudeFableTransportAllowsFirstPartyHaikuAuxiliaryUsage()
        async throws
    {
        let runner = FakeClaudeSubscriptionProcessRunner(
            results: [
                ChatNativeClaudeProcessResult(
                    exitCode: 0,
                    stdout: Data(
                        #"{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","subscriptionType":"max"}"#
                            .utf8),
                    stderr: Data()),
                ChatNativeClaudeProcessResult(
                    exitCode: 0,
                    stdout: Data(
                        #"{"is_error":false,"subtype":"success","modelUsage":{"claude-haiku-4-5-20251001":{"canonicalModel":"claude-haiku-4-5","provider":"firstParty","outputTokens":18},"claude-fable-5":{"canonicalModel":"claude-fable-5","provider":"firstParty","outputTokens":192}},"structured_output":{"kind":"assistant_text","text":"FABLE_NATIVE_OK"}}"#
                            .utf8),
                    stderr: Data()),
            ])
        let transport = ChatNativeClaudeSubscriptionModelTransport(
            modelID: "fable-5",
            effort: "medium",
            workspaceRoot: "/tmp/project",
            scratchDirectoryURL: URL(
                fileURLWithPath: "/tmp/tatwo-fable-auxiliary-test"),
            profileHomeURL: URL(
                fileURLWithPath: "/Users/example",
                isDirectory: true),
            runnerFactory: { runner })

        let turn = try await transport.respond(
            to: TatwoNativeModelRequest(
                input: [.userText("Keep the exact Fable route.")],
                tools: [],
                modelStep: 1))

        XCTAssertEqual(
            turn,
            TatwoNativeModelTurn(
                response: .assistantText("FABLE_NATIVE_OK"),
                attestation: TatwoNativeModelAttestation(
                    modelID: "fable-5",
                    effort: "medium",
                    fallbackCount: 0)))
    }

    func testClaudeFableTransportRejectsOpusFallbackAttestation() async {
        let runner = FakeClaudeSubscriptionProcessRunner(
            results: [
                ChatNativeClaudeProcessResult(
                    exitCode: 0,
                    stdout: Data(
                        #"{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","subscriptionType":"max"}"#
                            .utf8),
                    stderr: Data()),
                ChatNativeClaudeProcessResult(
                    exitCode: 0,
                    stdout: Data(
                        #"{"is_error":false,"subtype":"success","modelUsage":{"claude-opus-5":{"canonicalModel":"claude-opus-5","provider":"firstParty","outputTokens":64}},"structured_output":{"kind":"assistant_text","text":"WRONG_MODEL"}}"#
                            .utf8),
                    stderr: Data()),
            ])
        let transport = ChatNativeClaudeSubscriptionModelTransport(
            modelID: "fable-5",
            effort: "medium",
            workspaceRoot: "/tmp/project",
            scratchDirectoryURL: URL(
                fileURLWithPath: "/tmp/tatwo-fable-fallback-test"),
            profileHomeURL: URL(
                fileURLWithPath: "/Users/example",
                isDirectory: true),
            runnerFactory: { runner })

        do {
            _ = try await transport.respond(
                to: TatwoNativeModelRequest(
                    input: [.userText("Do not fall back.")],
                    tools: [],
                    modelStep: 1))
            XCTFail("Fable must fail closed when Claude reports Opus")
        } catch let error as ChatNativeClaudeSubscriptionRuntimeError {
            XCTAssertEqual(error, .modelAttestationMismatch)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testGrokAccountStatusRejectsExpiredSubscriptionEvenWhenModelsExitZero()
    {
        let status =
            ChatNativeGrokSubscriptionAccountService.accountStatus(
                from: ChatNativeGrokProcessResult(
                    exitCode: 0,
                    stdout: Data(
                        """
                        You are not authenticated.
                        Default model: grok-build
                        Available models:
                          * grok-build (default)
                        """.utf8),
                    stderr: Data(
                        "auth: token expired, re-authentication required"
                            .utf8)))

        XCTAssertEqual(status, .signedOut)
    }

    func testGrokAccountServiceOpensExactOAuthURLFromRuntimeStream()
        async
    {
        let authorizationURL =
            "https://auth.x.ai/oauth2/authorize"
            + "?client_id=tatwo-test&state=bounded"
        let runner = FakeGrokSubscriptionProcessRunner(
            results: [
                ChatNativeGrokProcessResult(
                    exitCode: 0,
                    stdout: Data(),
                    stderr: Data()),
                ChatNativeGrokProcessResult(
                    exitCode: 0,
                    stdout: Data(
                        """
                        You are logged in with grok.com.
                        Default model: grok-4.6
                        Available models:
                          * grok-4.6 (default)
                        """.utf8),
                    stderr: Data()),
            ],
            outputChunks: [
                [
                    Data("Open this URL to sign in:\n  https://auth.x.ai/"
                        .utf8),
                    Data(
                        "oauth2/authorize?client_id=tatwo-test&state=bounded\n"
                            .utf8),
                ],
                [],
            ])
        let openedURL = LockedURLCapture()
        let service = ChatNativeGrokSubscriptionAccountService(
            homeLocator: ChatNativeGrokSubscriptionHomeLocator(
                environment: [
                    "TATWO_NATIVE_GROK_SUBSCRIPTION_HOME":
                        "/tmp/tatwo-grok-login-home",
                ]),
            runnerFactory: { runner })

        let outcome = await service.login(
            openURL: { url in
                openedURL.record(url)
                return true
            })

        XCTAssertEqual(openedURL.value?.absoluteString, authorizationURL)
        XCTAssertEqual(outcome, .completed(.signedIn))
        let invocations = await runner.invocations
        XCTAssertEqual(invocations.first?.arguments, ["login", "--oauth"])
        XCTAssertEqual(invocations.last?.arguments, ["models"])
    }

    func testGrokAccountServiceAcceptsAccountsXAIAndPublishesAwaitingCode()
        async
    {
        let runner = FakeGrokSubscriptionProcessRunner(
            results: [
                ChatNativeGrokProcessResult(
                    exitCode: 0,
                    stdout: Data(),
                    stderr: Data()),
                ChatNativeGrokProcessResult(
                    exitCode: 1,
                    stdout: Data(),
                    stderr: Data()),
            ],
            outputChunks: [[
                Data(
                    """
                    Open https://accounts.x.ai/device
                    Paste the verification code shown in your browser:
                    """.utf8),
            ]])
        let openedURL = LockedURLCapture()
        let awaitingCode = LockedBoolCapture()
        let service = ChatNativeGrokSubscriptionAccountService(
            homeLocator: ChatNativeGrokSubscriptionHomeLocator(
                environment: [
                    "TATWO_NATIVE_GROK_SUBSCRIPTION_HOME":
                        "/tmp/tatwo-grok-accounts-login-home",
                ]),
            runnerFactory: { runner })

        _ = await service.login(
            openURL: { url in
                openedURL.record(url)
                return true
            },
            onAwaitingVerificationCode: {
                awaitingCode.record(true)
            })

        XCTAssertEqual(
            openedURL.value?.absoluteString,
            "https://accounts.x.ai/device")
        XCTAssertEqual(awaitingCode.value, true)
    }

    @MainActor
    func testGrokOnboardingPublishesAwaitingCodeAndSendsCodeToStdin()
        async
    {
        let runner = FakeGrokSubscriptionProcessRunner(
            results: [
                ChatNativeGrokProcessResult(
                    exitCode: 0,
                    stdout: Data(),
                    stderr: Data()),
                ChatNativeGrokProcessResult(
                    exitCode: 0,
                    stdout: Data(
                        "Default model: grok-4.6".utf8),
                    stderr: Data()),
            ],
            outputChunks: [[
                Data(
                    """
                    Open https://x.ai/device
                    Enter verification code:
                    """.utf8),
            ]],
            interactiveWaitsForInput: true)
        let model = ChatNativeGrokSubscriptionOnboardingModel(
            accountService: ChatNativeGrokSubscriptionAccountService(
                homeLocator: ChatNativeGrokSubscriptionHomeLocator(
                    environment: [
                        "TATWO_NATIVE_GROK_SUBSCRIPTION_HOME":
                            "/tmp/tatwo-grok-code-login-home",
                    ]),
                runnerFactory: { runner }),
            openURL: { _ in true })

        let signInTask = Task { @MainActor in
            await model.signIn()
        }
        for _ in 0..<100 where !model.awaitingVerificationCode {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(model.awaitingVerificationCode)

        await model.submitVerificationCode("  ABC-123  ")
        await signInTask.value

        let sentLines = await runner.sentInteractiveLines
        XCTAssertEqual(sentLines, ["ABC-123"])
        XCTAssertEqual(model.status, .signedIn)
        XCTAssertFalse(model.awaitingVerificationCode)
        XCTAssertFalse(model.isWorking)
    }

    @MainActor
    func testGrokOnboardingTimeoutResetsWorkingState() async {
        let runner = FakeGrokSubscriptionProcessRunner(
            results: [
                ChatNativeGrokProcessResult(
                    exitCode: 0,
                    stdout: Data(),
                    stderr: Data()),
            ],
            outputChunks: [[
                Data("Open https://auth.x.ai/device\n".utf8),
            ]],
            interactiveNeverExits: true)
        let model = ChatNativeGrokSubscriptionOnboardingModel(
            accountService: ChatNativeGrokSubscriptionAccountService(
                homeLocator: ChatNativeGrokSubscriptionHomeLocator(
                    environment: [
                        "TATWO_NATIVE_GROK_SUBSCRIPTION_HOME":
                            "/tmp/tatwo-grok-timeout-home",
                    ]),
                runnerFactory: { runner },
                loginTimeoutNanoseconds: 1_000_000),
            openURL: { _ in true })

        await model.signIn()

        XCTAssertFalse(model.isWorking)
        XCTAssertFalse(model.awaitingVerificationCode)
        XCTAssertEqual(model.status, .signedOut)
        XCTAssertEqual(
            model.notice,
            "Grok 登入已逾時（180 秒），請重新登入。")
    }

    func testGrokTransportUsesSubscriptionOnlyAndAttestsExactGrok46High()
        async throws
    {
        let runner = FakeGrokSubscriptionProcessRunner(
            results: [
                ChatNativeGrokProcessResult(
                    exitCode: 0,
                    stdout: Data(
                        """
                        You are logged in with grok.com.
                        Default model: grok-4.6
                        Available models:
                          * grok-4.6 (default)
                        """.utf8),
                    stderr: Data()),
                ChatNativeGrokProcessResult(
                    exitCode: 0,
                    stdout: Data(
                        #"{"text":"{\"kind\":\"assistant_text\",\"text\":\"GROK_NATIVE_OK\"}","stopReason":"EndTurn","sessionId":"session-grok","requestId":"request-grok"}"#
                            .utf8),
                    stderr: Data()),
            ])
        let transport = ChatNativeGrokSubscriptionModelTransport(
            modelID: "grok-build",
            effort: "high",
            workspaceRoot: "/tmp/project",
            scratchDirectoryURL: URL(
                fileURLWithPath: "/tmp/tatwo-grok-native-test"),
            homeURL: URL(
                fileURLWithPath: "/tmp/tatwo-grok-home",
                isDirectory: true),
            runnerFactory: { runner },
            evidenceLoader: { sessionID, requestID, _ in
                XCTAssertEqual(sessionID, "session-grok")
                XCTAssertEqual(requestID, "request-grok")
                return ChatNativeGrokSessionEvidence(
                    configuredModelID: "grok-4.6",
                    turnModelID: "grok-4.6",
                    assistantModelID: "grok-4.6-build",
                    requestID: "request-grok")
            })

        let turn = try await transport.respond(
            to: TatwoNativeModelRequest(
                input: [.userText("Inspect the Aurora theme.")],
                tools: [],
                modelStep: 1))

        XCTAssertEqual(
            turn,
            TatwoNativeModelTurn(
                response: .assistantText("GROK_NATIVE_OK"),
                attestation: TatwoNativeModelAttestation(
                    modelID: "grok-build",
                    effort: "high",
                    fallbackCount: 0)))
        let recordedInvocations = await runner.invocations
        XCTAssertEqual(recordedInvocations.first?.arguments, ["models"])
        let invocation = try XCTUnwrap(recordedInvocations.last)
        XCTAssertEqual(
            argumentValue(after: "--model", in: invocation.arguments),
            "grok-4.6")
        XCTAssertEqual(
            argumentValue(after: "--effort", in: invocation.arguments),
            "high")
        XCTAssertEqual(
            argumentValue(
                after: "--reasoning-effort",
                in: invocation.arguments),
            "high")
        XCTAssertTrue(invocation.arguments.contains("--no-memory"))
        XCTAssertTrue(invocation.arguments.contains("--no-subagents"))
        XCTAssertTrue(invocation.arguments.contains("--disable-web-search"))
        XCTAssertEqual(
            argumentValue(after: "--permission-mode", in: invocation.arguments),
            "dontAsk")
        XCTAssertEqual(
            argumentValue(after: "--tools", in: invocation.arguments),
            "")
        XCTAssertEqual(
            argumentValue(after: "--prompt-file", in: invocation.arguments),
            "/dev/stdin")
        for key in [
            "XAI_API_KEY",
            "GROK_API_KEY",
            "OPENAI_API_KEY",
            "ANTHROPIC_API_KEY",
        ] {
            XCTAssertNil(invocation.environment[key])
        }
    }

    func testGrokTransportRejectsNon46SessionEvidence() async {
        let runner = FakeGrokSubscriptionProcessRunner(
            results: [
                ChatNativeGrokProcessResult(
                    exitCode: 0,
                    stdout: Data(
                        "You are logged in with grok.com.\nDefault model: grok-4.6\n"
                            .utf8),
                    stderr: Data()),
                ChatNativeGrokProcessResult(
                    exitCode: 0,
                    stdout: Data(
                        #"{"text":"{\"kind\":\"assistant_text\",\"text\":\"WRONG_MODEL\"}","stopReason":"EndTurn","sessionId":"session-grok","requestId":"request-grok"}"#
                            .utf8),
                    stderr: Data()),
            ])
        let transport = ChatNativeGrokSubscriptionModelTransport(
            modelID: "grok-build",
            effort: "high",
            workspaceRoot: "/tmp/project",
            scratchDirectoryURL: URL(
                fileURLWithPath: "/tmp/tatwo-grok-mismatch-test"),
            homeURL: URL(
                fileURLWithPath: "/tmp/tatwo-grok-home",
                isDirectory: true),
            runnerFactory: { runner },
            evidenceLoader: { _, _, _ in
                ChatNativeGrokSessionEvidence(
                    configuredModelID: "grok-4.5",
                    turnModelID: "grok-4.5",
                    assistantModelID: "grok-4.5-build",
                    requestID: "request-grok")
            })

        do {
            _ = try await transport.respond(
                to: TatwoNativeModelRequest(
                    input: [.userText("Do not substitute models.")],
                    tools: [],
                    modelStep: 1))
            XCTFail("Grok 4.6 route must fail closed on 4.5 evidence")
        } catch let error as ChatNativeGrokSubscriptionRuntimeError {
            XCTAssertEqual(error, .modelAttestationMismatch)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testClaudeTransportClassifiesSubscriptionSessionLimit()
        async throws
    {
        let runner = FakeClaudeSubscriptionProcessRunner(
            results: [
                ChatNativeClaudeProcessResult(
                    exitCode: 0,
                    stdout: Data(
                        #"{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","subscriptionType":"max"}"#
                            .utf8),
                    stderr: Data()),
                ChatNativeClaudeProcessResult(
                    exitCode: 1,
                    stdout: Data(
                        #"{"is_error":true,"terminal_reason":"api_error","api_error_status":429,"result":"You've hit your session limit · resets 1:20am (Asia/Taipei)","type":"result"}"#
                            .utf8),
                    stderr: Data()),
            ])
        let transport = ChatNativeClaudeSubscriptionModelTransport(
            modelID: "opus-5",
            effort: "high",
            workspaceRoot: "/tmp/project",
            scratchDirectoryURL: URL(
                fileURLWithPath: "/tmp/tatwo-claude-limit-test"),
            homeLocator: ChatNativeClaudeSubscriptionHomeLocator(
                environment: [
                    "TATWO_NATIVE_CLAUDE_SUBSCRIPTION_HOME":
                        "/tmp/tatwo-claude-home",
                ]),
            profileHomeURL: URL(
                fileURLWithPath: "/Users/example",
                isDirectory: true),
            runnerFactory: { runner })

        do {
            _ = try await transport.respond(
                to: TatwoNativeModelRequest(
                    input: [.userText("Continue the Goal.")],
                    tools: [],
                    modelStep: 1))
            XCTFail("Expected subscription session limit")
        } catch let error as ChatNativeClaudeSubscriptionRuntimeError {
            XCTAssertEqual(error, .subscriptionSessionLimit)
            XCTAssertEqual(
                error.nativeFailureCode,
                "claude_subscription_session_limit")
        }
    }

    private func decodeObject(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func argumentValue(
        after flag: String,
        in arguments: [String]
    ) -> String? {
        guard let index = arguments.firstIndex(of: flag),
              arguments.indices.contains(index + 1)
        else { return nil }
        return arguments[index + 1]
    }

    private func testUsageProvider(
        id: String,
        displayName: String
    ) -> UsageProviderStatus {
        UsageProviderStatus(
            id: id,
            displayName: displayName,
            status: .installed,
            cachePolicy: "test",
            liveRefreshPolicy: "test",
            quotaLabel: "test")
    }
}

private struct FixedClaudeOAuthUsageClient:
    ClaudeOAuthUsageQuerying
{
    func queryUsage() async throws -> ClaudeOAuthUsage {
        ClaudeOAuthUsage(
            fiveHour: .init(
                utilization: 10,
                resetsAt: nil),
            sevenDay: .init(
                utilization: 20,
                resetsAt: nil))
    }
}

private actor FakeClaudeSubscriptionProcessRunner:
    ChatNativeClaudeProcessRunning
{
    struct Invocation: Sendable {
        let arguments: [String]
        let standardInput: Data?
        let environment: [String: String]
        let currentDirectoryURL: URL
    }

    private var remainingResults: [ChatNativeClaudeProcessResult]
    private(set) var invocations: [Invocation] = []

    init(results: [ChatNativeClaudeProcessResult]) {
        self.remainingResults = results
    }

    func run(
        arguments: [String],
        standardInput: Data?,
        environment: [String: String],
        currentDirectoryURL: URL
    ) async throws -> ChatNativeClaudeProcessResult {
        invocations.append(Invocation(
            arguments: arguments,
            standardInput: standardInput,
            environment: environment,
            currentDirectoryURL: currentDirectoryURL))
        guard !remainingResults.isEmpty else {
            throw ChatNativeClaudeSubscriptionRuntimeError.processExited
        }
        return remainingResults.removeFirst()
    }

    nonisolated func stop() {}
}

private actor FakeGrokSubscriptionProcessRunner:
    ChatNativeGrokProcessRunning
{
    struct Invocation: Sendable {
        let arguments: [String]
        let standardInput: Data?
        let environment: [String: String]
        let currentDirectoryURL: URL
    }

    private var remainingResults: [ChatNativeGrokProcessResult]
    private var remainingOutputChunks: [[Data]]
    private let interactiveWaitsForInput: Bool
    private let interactiveNeverExits: Bool
    private var interactiveSessions:
        [FakeGrokInteractiveProcessSession] = []
    private(set) var invocations: [Invocation] = []

    init(
        results: [ChatNativeGrokProcessResult],
        outputChunks: [[Data]] = [],
        interactiveWaitsForInput: Bool = false,
        interactiveNeverExits: Bool = false
    ) {
        self.remainingResults = results
        self.remainingOutputChunks = outputChunks
        self.interactiveWaitsForInput = interactiveWaitsForInput
        self.interactiveNeverExits = interactiveNeverExits
    }

    func run(
        arguments: [String],
        standardInput: Data?,
        environment: [String: String],
        currentDirectoryURL: URL
    ) async throws -> ChatNativeGrokProcessResult {
        invocations.append(Invocation(
            arguments: arguments,
            standardInput: standardInput,
            environment: environment,
            currentDirectoryURL: currentDirectoryURL))
        guard !remainingResults.isEmpty else {
            throw ChatNativeGrokSubscriptionRuntimeError.processExited
        }
        return remainingResults.removeFirst()
    }

    func run(
        arguments: [String],
        standardInput: Data?,
        environment: [String: String],
        currentDirectoryURL: URL,
        outputHandler: @escaping @Sendable (Data) -> Void
    ) async throws -> ChatNativeGrokProcessResult {
        invocations.append(Invocation(
            arguments: arguments,
            standardInput: standardInput,
            environment: environment,
            currentDirectoryURL: currentDirectoryURL))
        if !remainingOutputChunks.isEmpty {
            for chunk in remainingOutputChunks.removeFirst() {
                outputHandler(chunk)
            }
        }
        guard !remainingResults.isEmpty else {
            throw ChatNativeGrokSubscriptionRuntimeError.processExited
        }
        return remainingResults.removeFirst()
    }

    func startInteractive(
        arguments: [String],
        environment: [String: String],
        currentDirectoryURL: URL,
        outputHandler: @escaping @Sendable (Data) -> Void
    ) async throws -> any ChatNativeGrokInteractiveProcessSession {
        invocations.append(Invocation(
            arguments: arguments,
            standardInput: nil,
            environment: environment,
            currentDirectoryURL: currentDirectoryURL))
        if !remainingOutputChunks.isEmpty {
            for chunk in remainingOutputChunks.removeFirst() {
                outputHandler(chunk)
            }
        }
        guard !remainingResults.isEmpty else {
            throw ChatNativeGrokSubscriptionRuntimeError.processExited
        }
        let session = FakeGrokInteractiveProcessSession(
            result: remainingResults.removeFirst(),
            waitsForInput: interactiveWaitsForInput,
            neverExits: interactiveNeverExits)
        interactiveSessions.append(session)
        return session
    }

    var sentInteractiveLines: [String] {
        interactiveSessions.flatMap(\.sentLines)
    }

    nonisolated func stop() {}
}

private final class FakeGrokInteractiveProcessSession:
    ChatNativeGrokInteractiveProcessSession,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let result: ChatNativeGrokProcessResult
    private let waitsForInput: Bool
    private let neverExits: Bool
    private var running: Bool
    private var storedLines: [String] = []

    init(
        result: ChatNativeGrokProcessResult,
        waitsForInput: Bool,
        neverExits: Bool
    ) {
        self.result = result
        self.waitsForInput = waitsForInput
        self.neverExits = neverExits
        self.running = waitsForInput || neverExits
    }

    var isRunning: Bool {
        lock.withLock { running }
    }

    var sentLines: [String] {
        lock.withLock { storedLines }
    }

    func send(line: String) async throws {
        try lock.withLock {
            guard running else {
                throw ChatNativeGrokSubscriptionRuntimeError.processExited
            }
            storedLines.append(line)
            if waitsForInput && !neverExits {
                running = false
            }
        }
    }

    func waitForExit() async throws -> ChatNativeGrokProcessResult {
        while isRunning {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        return result
    }

    func terminate() {
        lock.withLock { running = false }
    }
}

private final class LockedURLCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: URL?

    var value: URL? {
        lock.withLock { storedValue }
    }

    func record(_ value: URL) {
        lock.withLock { storedValue = value }
    }
}

private final class LockedBoolCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Bool?

    var value: Bool? {
        lock.withLock { storedValue }
    }

    func record(_ value: Bool) {
        lock.withLock { storedValue = value }
    }
}

private actor LoginSubscriptionAppServerSession:
    ChatNativeSubscriptionAppServerSession
{
    private var accountReads = 0
    private var deliveredCompletion = false

    func request(
        method: String,
        params: Data
    ) async throws -> Data {
        switch method {
        case "initialize":
            return Data(#"{"codexHome":"/tmp/tatwo"}"#.utf8)
        case "account/login/start":
            return Data(
                #"{"type":"chatgpt","loginId":"login-1","authUrl":"https://auth.openai.com/tatwo-test"}"#
                    .utf8)
        case "account/read":
            accountReads += 1
            return Data(
                #"{"account":{"type":"chatgpt","email":"owner@example.invalid","planType":"pro"},"requiresOpenaiAuth":true}"#
                    .utf8)
        default:
            throw ChatNativeSubscriptionRuntimeError.invalidProtocol
        }
    }

    func notify(method: String, params: Data) async throws {}

    func nextMessage() async throws -> Data {
        guard !deliveredCompletion else {
            throw ChatNativeSubscriptionRuntimeError.processExited
        }
        deliveredCompletion = true
        return Data(
            #"{"method":"account/login/completed","params":{"loginId":"login-1","success":true,"error":null}}"#
                .utf8)
    }

    func respond(
        id: ChatNativeSubscriptionJSONRPCID,
        result: Data
    ) async throws {}

    func stop() async {}
}

private actor FakeSubscriptionAppServerSession:
    ChatNativeSubscriptionAppServerSession
{
    private let responses: [String: String]
    private var messages: [String]
    private var recordedParams: [String: Data] = [:]
    private var requestCounts: [String: Int] = [:]
    private var serverResponses:
        [ChatNativeSubscriptionJSONRPCID: Data] = [:]

    init(responses: [String: String], messages: [String]) {
        self.responses = responses
        self.messages = messages
    }

    func request(
        method: String,
        params: Data
    ) async throws -> Data {
        recordedParams[method] = params
        requestCounts[method, default: 0] += 1
        guard let raw = responses[method] else {
            throw ChatNativeSubscriptionRuntimeError.invalidProtocol
        }
        return Data(raw.utf8)
    }

    func notify(
        method: String,
        params: Data
    ) async throws {}

    func nextMessage() async throws -> Data {
        guard !messages.isEmpty else {
            throw ChatNativeSubscriptionRuntimeError.processExited
        }
        let raw = messages.removeFirst()
        return Data(raw.utf8)
    }

    func respond(
        id: ChatNativeSubscriptionJSONRPCID,
        result: Data
    ) async throws {
        serverResponses[id] = result
    }

    func stop() async {}

    func params(for method: String) -> Data? {
        recordedParams[method]
    }

    func requestCount(for method: String) -> Int {
        requestCounts[method, default: 0]
    }

    func serverResponse(
        id: ChatNativeSubscriptionJSONRPCID
    ) -> Data? {
        serverResponses[id]
    }
}
