// 照搬自 Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/EmbeddedBrowserRuntimePolicies.swift；改動 3 行（原因：加入照搬來源標記；移除薄殼不可依賴的 TatwoCEFBridge、TatwoUltraworkCore import）
import AppKit
import SwiftUI
import WebKit
import Darwin

// MARK: - Browser view

enum EmbeddedBrowserProfileAccessState: Equatable, Sendable {
    case checking(profileKey: UUID)
    case ready(profileKey: UUID)
    case blocked(profileKey: UUID, failure: EmbeddedBrowserProfileAccessFailure)

    func isReady(for profileKey: UUID) -> Bool {
        self == .ready(profileKey: profileKey)
    }
}

enum EmbeddedBrowserRuntimeMountPolicy {
    static func allowsMount(
        state: EmbeddedBrowserProfileAccessState,
        profileKey: UUID
    ) -> Bool {
        state.isReady(for: profileKey)
    }

    static func makeRuntimeIfAuthorized<Runtime>(
        state: EmbeddedBrowserProfileAccessState,
        profileKey: UUID,
        factory: () -> Runtime
    ) -> Runtime? {
        guard allowsMount(state: state, profileKey: profileKey) else {
            return nil
        }
        return factory()
    }
}

enum EmbeddedBrowserRuntimeFailurePresentation {
    static func startupFailureMessage(
        engine: EmbeddedBrowserEngine,
        currentURLString _: String,
        phase: EmbeddedBrowserLoadPhase = .startupFailed,
        visibleError: EmbeddedBrowserVisibleError?
    ) -> String? {
        guard engine == .chromiumCEF,
              phase == .startupFailed,
              let visibleError
        else {
            return nil
        }
        return visibleError.message
    }
}

enum EmbeddedBrowserActivePageRetentionPolicy {
    static func shouldClearActivePage(
        for state: EmbeddedBrowserNavigationState
    ) -> Bool {
        guard state.urlString == nil,
              state.committedMainFrameURLString == nil
        else {
            return false
        }
        switch state.phase {
        case .blank, .startupFailed, .closed:
            return true
        case .creating, .loading, .committed, .finished,
             .blockedBySecurity, .navigationFailed, .rendererFailed:
            return false
        }
    }
}

enum EmbeddedBrowserCommandDispatchPolicy {
    @discardableResult
    static func dispatch(
        _ action: EmbeddedBrowserCommand.Action,
        state: EmbeddedBrowserProfileAccessState,
        profileKey: UUID,
        sink: (EmbeddedBrowserCommand.Action) -> Void
    ) -> Bool {
        guard state.isReady(for: profileKey) else { return false }
        sink(action)
        return true
    }
}

enum EmbeddedBrowserStartPageSubmission {
    static func navigationURL(for rawValue: String) -> URL? {
        guard case let .navigate(url) =
            TatwoBrowserAddressResolver.resolve(rawValue)
        else {
            return nil
        }
        return url
    }
}

enum EmbeddedBrowserUIFixturePolicy {
    static func isEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environment["TATWO_BROWSER_UI_FIXTURE"] == "1"
    }

    static func allowsRealActions(isFixture: Bool) -> Bool {
        !isFixture
    }

    @discardableResult
    static func performRealAction(
        isFixture: Bool,
        action: () -> Void
    ) -> Bool {
        guard allowsRealActions(isFixture: isFixture) else {
            return false
        }
        action()
        return true
    }

    static func bookmarks(
        profileKey: UUID
    ) -> [EmbeddedBrowserBookmark] {
        let fixtureDate = Date(timeIntervalSince1970: 1_788_192_000)
        return [
            EmbeddedBrowserBookmark(
                id: UUID(
                    uuidString: "cb5a3730-324a-476f-bd4d-060351df6df1")!,
                profileKey: profileKey,
                url: "https://developer.apple.com/",
                title: "Apple Developer",
                createdAt: fixtureDate),
            EmbeddedBrowserBookmark(
                id: UUID(
                    uuidString: "1828a564-b983-49b1-9cd6-61d9a300b04b")!,
                profileKey: profileKey,
                url: "https://chatgpt.com/",
                title: "ChatGPT",
                createdAt: fixtureDate.addingTimeInterval(1)),
            EmbeddedBrowserBookmark(
                id: UUID(
                    uuidString: "bc07b9e1-a7d5-4c91-9fa9-cdaaf7318ccb")!,
                profileKey: profileKey,
                url: "https://www.google.com/",
                title: "Google",
                createdAt: fixtureDate.addingTimeInterval(2)),
        ]
    }
}
