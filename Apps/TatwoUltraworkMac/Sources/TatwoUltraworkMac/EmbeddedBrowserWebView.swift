import AppKit
import SwiftUI
import TatwoCEFBridge
import TatwoUltraworkCore
import WebKit
import Darwin

private struct EmbeddedBrowserHistoryRestoration {
    let urls: [URL]
    let targetIndex: Int
    var nextLoadIndex: Int
    var isMovingToTarget: Bool
}

struct EmbeddedBrowserWebView: NSViewRepresentable {
    private static let annotationContentWorld = WKContentWorld.world(
        name: "com.tatwo.browser.annotation")

    let profile: EmbeddedBrowserRuntimeProfile
    let initialURL: URL
    let command: EmbeddedBrowserCommand?
    let annotationStore: EmbeddedBrowserAnnotationStore
    let onNavigationStateChange: (EmbeddedBrowserNavigationState) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            profile: profile,
            annotationStore: annotationStore,
            navigationJournalStore: .live,
            onNavigationStateChange: onNavigationStateChange)
    }

    func makeNSView(context: Context) -> WKWebView {
        let acquisition = EmbeddedBrowserWebViewRegistry.shared.acquire(
            profile: profile,
            ownerID: context.coordinator.leaseID
        ) {
            let configuration = WKWebViewConfiguration.tatwoBrowserConfiguration(
                profile: profile)
            let script = WKUserScript(
                source: Self.annotationJS,
                injectionTime: .atDocumentEnd,
                // 只注入主框架：註解庫依頂層 URL 查詢，iframe 註解不會混入頂層紀錄。
                forMainFrameOnly: true,
                in: Self.annotationContentWorld
            )
            configuration.userContentController.addUserScript(script)
            return WKWebView(frame: .zero, configuration: configuration)
        }

        guard case let .success(resolved) = acquisition else {
            context.coordinator.hasActiveLease = false
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            return WKWebView(frame: .zero, configuration: configuration)
        }

        context.coordinator.hasActiveLease = true
        let webView = resolved.webView
        let controller = webView.configuration.userContentController
        controller.removeScriptMessageHandler(
            forName: "tatwoAnnotate",
            contentWorld: Self.annotationContentWorld)
        controller.add(
            context.coordinator,
            contentWorld: Self.annotationContentWorld,
            name: "tatwoAnnotate")
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.isInspectable = EmbeddedBrowserAutomationExposurePolicy
            .exposesCDPEndpoint
        webView.allowsBackForwardNavigationGestures = true
        if webView.url?.absoluteString != initialURL.absoluteString {
            webView.load(URLRequest(url: initialURL))
        } else {
            context.coordinator.publishState(for: webView)
        }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onNavigationStateChange = onNavigationStateChange

        guard context.coordinator.hasActiveLease,
              let command,
              command.id != context.coordinator.lastCommandID
        else {
            return
        }

        context.coordinator.lastCommandID = command.id
        switch command.action {
        case let .load(url):
            switch EmbeddedBrowserNavigationPolicy.decision(for: url) {
            case .allow:
                webView.load(URLRequest(url: url))
            case let .block(reason):
                context.coordinator.record(
                    .blockedNavigation(reason),
                    for: webView)
            }
        case .goBack:
            if webView.canGoBack { webView.goBack() }
        case .goForward:
            if webView.canGoForward { webView.goForward() }
        case .reload:
            if webView.url != nil { webView.reload() }
        }
        context.coordinator.publishState(for: webView)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        // The registry verifies the lease before detaching handlers. A stale
        // SwiftUI dismantle therefore cannot tear down a newly attached pane.
        EmbeddedBrowserWebViewRegistry.shared.release(
            profile: coordinator.profile,
            ownerID: coordinator.leaseID,
            webView: webView)
        coordinator.hasActiveLease = false
    }

    final class Coordinator:
        NSObject,
        WKNavigationDelegate,
        WKScriptMessageHandler,
        WKUIDelegate
    {
        let leaseID = UUID()
        let profile: EmbeddedBrowserRuntimeProfile
        var hasActiveLease = false
        var lastCommandID: UUID?
        var visibleError: EmbeddedBrowserVisibleError?
        var isLoading = false
        var phase: EmbeddedBrowserLoadPhase = .blank
        var committedMainFrameURLString: String?
        var httpStatusCode: Int?
        var structuredError: EmbeddedBrowserNavigationError?
        let annotationStore: EmbeddedBrowserAnnotationStore
        let navigationJournalStore: EmbeddedBrowserNavigationJournalStore
        var onNavigationStateChange: (EmbeddedBrowserNavigationState) -> Void
        private var historyRestoration:
            EmbeddedBrowserHistoryRestoration?

        init(
            profile: EmbeddedBrowserRuntimeProfile,
            annotationStore: EmbeddedBrowserAnnotationStore,
            navigationJournalStore: EmbeddedBrowserNavigationJournalStore,
            onNavigationStateChange: @escaping (EmbeddedBrowserNavigationState) -> Void
        ) {
            self.profile = profile
            self.annotationStore = annotationStore
            self.navigationJournalStore = navigationJournalStore
            self.onNavigationStateChange = onNavigationStateChange
        }

        // 接收注入 JS 傳回的選取文字，存進註解庫。
        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == "tatwoAnnotate",
                  message.frameInfo.isMainFrame,
                  let body = message.body as? [String: Any],
                  let annotation = EmbeddedBrowserAnnotationPolicy.candidate(
                    isMainFrame: message.frameInfo.isMainFrame,
                    text: body["text"] as? String,
                    committedURLString: committedMainFrameURLString,
                    currentNativeURLString:
                        message.webView?.url?.absoluteString,
                    nativeTitle: message.webView?.title,
                    profileKey: profile.registryKey)
            else { return }
            DispatchQueue.main.async { [weak self] in
                self?.annotationStore.add(annotation)
            }
        }

        func webView(
            _ webView: WKWebView,
            didStartProvisionalNavigation navigation: WKNavigation!
        ) {
            visibleError = nil
            isLoading = true
            phase = .loading
            httpStatusCode = nil
            structuredError = nil
            publishState(for: webView)
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            visibleError = nil
            phase = .committed
            committedMainFrameURLString = webView.url?.absoluteString
            structuredError = nil
            publishState(for: webView)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            visibleError = nil
            isLoading = false
            phase = .finished
            committedMainFrameURLString = webView.url?.absoluteString
            structuredError = nil
            if advanceHistoryRestoration(in: webView) {
                publishState(for: webView)
                return
            }
            persistHistory(from: webView)
            publishState(for: webView)
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: Error
        ) {
            if advanceHistoryRestoration(in: webView) {
                publishState(for: webView)
                return
            }
            recordLoadFailure(error, for: webView)
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            if advanceHistoryRestoration(in: webView) {
                publishState(for: webView)
                return
            }
            recordLoadFailure(error, for: webView)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable
                (WKNavigationActionPolicy) -> Void
        ) {
            if navigationAction.shouldPerformDownload {
                record(.downloadBlocked, for: webView)
                decisionHandler(.cancel)
                return
            }
            guard navigationAction.targetFrame != nil else {
                record(.popupBlocked, for: webView)
                decisionHandler(.cancel)
                return
            }
            switch EmbeddedBrowserNavigationPolicy.decision(
                for: navigationAction.request.url
            ) {
            case .allow:
                decisionHandler(.allow)
            case let .block(reason):
                record(.blockedNavigation(reason), for: webView)
                decisionHandler(.cancel)
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationResponse: WKNavigationResponse,
            decisionHandler: @escaping @MainActor @Sendable
                (WKNavigationResponsePolicy) -> Void
        ) {
            let httpResponse = navigationResponse.response as? HTTPURLResponse
            httpStatusCode = httpResponse?.statusCode
            let contentDisposition = httpResponse?
                .value(forHTTPHeaderField: "Content-Disposition")
            if let error = EmbeddedBrowserResponsePolicy.visibleError(
                url: navigationResponse.response.url,
                canShowMIMEType: navigationResponse.canShowMIMEType,
                contentDisposition: contentDisposition)
            {
                record(error, for: webView)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            record(.popupBlocked, for: webView)
            return nil
        }

        func webView(
            _ webView: WKWebView,
            requestMediaCapturePermissionFor origin: WKSecurityOrigin,
            initiatedByFrame frame: WKFrameInfo,
            type: WKMediaCaptureType,
            decisionHandler: @escaping @MainActor @Sendable
                (WKPermissionDecision) -> Void
        ) {
            let permission: EmbeddedBrowserSensitivePermission
            switch type {
            case .camera:
                permission = .camera
            case .microphone:
                permission = .microphone
            case .cameraAndMicrophone:
                permission = .cameraAndMicrophone
            @unknown default:
                permission = .cameraAndMicrophone
            }
            record(
                .sensitivePermissionBlocked(permission),
                for: webView)
            decisionHandler(
                EmbeddedBrowserSensitivePermissionPolicy.decision(
                    for: permission))
        }

        #if compiler(>=6.2)
        @available(macOS 26.0, *)
        func webView(
            _ webView: WKWebView,
            requestGeolocationPermissionFor origin: WKSecurityOrigin,
            initiatedByFrame frame: WKFrameInfo,
            decisionHandler: @escaping @MainActor @Sendable
                (WKPermissionDecision) -> Void
        ) {
            record(
                .sensitivePermissionBlocked(.geolocation),
                for: webView)
            decisionHandler(
                EmbeddedBrowserSensitivePermissionPolicy.decision(
                    for: .geolocation))
        }
        #endif

        func publishState(for webView: WKWebView) {
            let state = EmbeddedBrowserNavigationState(
                urlString: webView.url?.absoluteString,
                canGoBack: webView.canGoBack,
                canGoForward: webView.canGoForward,
                visibleError: visibleError,
                isLoading: isLoading,
                phase: phase,
                committedMainFrameURLString:
                    committedMainFrameURLString,
                httpStatusCode: httpStatusCode,
                structuredError: structuredError
            )
            onNavigationStateChange(state)
        }

        func record(
            _ error: EmbeddedBrowserVisibleError,
            for webView: WKWebView,
            code: Int? = nil
        ) {
            visibleError = error
            isLoading = false
            let kind: EmbeddedBrowserNavigationErrorKind
            switch error {
            case .blockedNavigation, .popupBlocked, .downloadBlocked,
                 .unsupportedContent, .sensitivePermissionBlocked:
                phase = .blockedBySecurity
                kind = .security
            case .loadFailed:
                phase = .navigationFailed
                kind = .navigation
            case .runtimeMessage:
                phase = .navigationFailed
                kind = .navigation
            }
            structuredError = EmbeddedBrowserNavigationError(
                kind: kind,
                code: code,
                message: error.message)
            publishState(for: webView)
        }

        private func recordLoadFailure(
            _ error: Error,
            for webView: WKWebView
        ) {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain,
               nsError.code == NSURLErrorCancelled
            {
                publishState(for: webView)
                return
            }
            record(.loadFailed, for: webView, code: nsError.code)
        }

        func restore(
            _ journal: EmbeddedBrowserNavigationJournal,
            in webView: WKWebView
        ) {
            let urls = journal.urls
            guard let first = urls.first,
                  urls.indices.contains(journal.currentIndex)
            else {
                publishState(for: webView)
                return
            }
            historyRestoration = EmbeddedBrowserHistoryRestoration(
                urls: urls,
                targetIndex: journal.currentIndex,
                nextLoadIndex: 1,
                isMovingToTarget: false)
            webView.load(URLRequest(url: first))
        }

        private func advanceHistoryRestoration(
            in webView: WKWebView
        ) -> Bool {
            guard var restoration = historyRestoration else {
                return false
            }
            if restoration.isMovingToTarget {
                historyRestoration = nil
                persistHistory(from: webView)
                return false
            }
            if restoration.urls.indices.contains(
                restoration.nextLoadIndex)
            {
                let nextURL = restoration.urls[
                    restoration.nextLoadIndex]
                restoration.nextLoadIndex += 1
                historyRestoration = restoration
                webView.load(URLRequest(url: nextURL))
                return true
            }
            guard restoration.targetIndex <
                    restoration.urls.count - 1,
                  webView.backForwardList.backList.indices.contains(
                    restoration.targetIndex)
            else {
                historyRestoration = nil
                persistHistory(from: webView)
                return false
            }
            restoration.isMovingToTarget = true
            historyRestoration = restoration
            webView.go(
                to: webView.backForwardList.backList[
                    restoration.targetIndex])
            return true
        }

        private func persistHistory(from webView: WKWebView) {
            guard historyRestoration == nil,
                  let currentItem = webView.backForwardList.currentItem
            else {
                return
            }
            let backURLs = webView.backForwardList.backList.map(\.url)
            let forwardURLs = webView.backForwardList.forwardList.map(\.url)
            let urls = backURLs + [currentItem.url] + forwardURLs
            guard let journal = EmbeddedBrowserNavigationJournal(
                urls: urls,
                currentIndex: backURLs.count)
            else {
                return
            }
            try? navigationJournalStore.save(journal, profile: profile)
        }
    }

    // 注入腳本：選取文字→浮出紫色「加註解」按鈕→點擊高亮 + 回傳 Swift。
    static let annotationJS = """
    (function(){
      if (window.__tatwoAnnotateInstalled) { return; }
      window.__tatwoAnnotateInstalled = true;
      var btn = document.createElement('div');
      btn.textContent = '🖊 加註解';
      btn.style.cssText = 'position:fixed;z-index:2147483647;display:none;padding:6px 11px;background:rgba(139,115,236,0.96);color:#fff;font:600 12px -apple-system,BlinkMacSystemFont,sans-serif;border-radius:9px;cursor:pointer;box-shadow:0 4px 16px rgba(0,0,0,0.28);user-select:none;';
      document.documentElement.appendChild(btn);
      var lastText = '';
      function hide(){ btn.style.display='none'; lastText=''; }
      document.addEventListener('mouseup', function(e){
        if (e.isTrusted !== true) { return; }
        setTimeout(function(){
          var sel = window.getSelection();
          var text = sel ? String(sel).trim() : '';
          if (text.length > 0 && e.target !== btn) {
            lastText = text;
            btn.style.left = Math.min(e.clientX, window.innerWidth - 110) + 'px';
            btn.style.top = Math.max(e.clientY - 42, 8) + 'px';
            btn.style.display = 'block';
          } else if (e.target !== btn) {
            hide();
          }
        }, 10);
      });
      document.addEventListener('scroll', hide, true);
      btn.addEventListener('mousedown', function(ev){ ev.preventDefault(); });
      btn.addEventListener('click', function(event){
        if (event.isTrusted !== true) { return; }
        if (!lastText) { return; }
        try {
          var sel = window.getSelection();
          if (sel && sel.rangeCount) {
            var range = sel.getRangeAt(0);
            var mark = document.createElement('mark');
            mark.style.cssText = 'background:rgba(193,168,236,0.55);border-radius:3px;padding:0 1px;';
            mark.setAttribute('data-tatwo-annot','1');
            range.surroundContents(mark);
            sel.removeAllRanges();
          }
        } catch(err) {}
        try {
          window.webkit.messageHandlers.tatwoAnnotate.postMessage({
            text: lastText
          });
        } catch(err) {}
        hide();
      });
    })();
    """
}
