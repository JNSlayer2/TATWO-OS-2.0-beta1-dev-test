import AppKit
import CoreText
import Foundation

/// Exercises the production SDK event -> message -> derived cache -> NSTextStorage path.
enum StreamingAppendAcceptance {
    @MainActor static func run() -> Bool {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["TATWO2_ISSUE_TEST_ROOT"],
              env["TATWO2_LIVE_ROOT"] == path + "/live",
              env["TATWO2_ENGINES_ROOT"] == path + "/engines",
              FileManager.default.fileExists(atPath: path + "/fixture-only") else { return false }
        let root = URL(fileURLWithPath: path)
        let store = ChatLiveStore(root: root.appendingPathComponent("live"))
        let engine = ChatLiveEngine(store: store, environment: env)
        let project = engine.newProject(name: "stream-fixture", workdir: path)
        let thread = engine.newThread(in: project)
        var passed = 0, failed = 0, notifications = 0
        func check(_ name: String, _ success: Bool) {
            if success { passed += 1 } else { failed += 1 }
            print("STREAMAPPENDTEST \(success ? "PASS" : "FAIL") \(name)")
        }
        engine.onChange = { notifications += 1 }
        func emit(_ text: String) {
            engine.handleSDK(thread, ["type": "stream_event", "event": [
                "type": "content_block_delta", "delta": ["type": "text_delta", "text": text]
            ]])
        }
        var expected = String(repeating: "正文段落內容。\n", count: 500)
        emit(expected)
        guard let first = engine.transcript(for: thread).last else { return false }
        let cache = ChatMessageDerivedValueCache()
        let storage = NSTextStorage()
        let controller = ChatStreamingPlainTextStorageController()
        let identity = ChatTranscriptPresentationIdentity(messageID: first.id,
            parserVersion: TatwoAssistantTranscriptCache.defaultParserVersion, sessionBoundaryGeneration: 1)
        func render(_ row: ChatMessage) {
            let derived = row.derivedSnapshot(using: cache)
            controller.apply(text: derived.transcriptDisplayText, fingerprint: derived.transcriptDisplayFingerprint,
                presentationIdentity: identity, sourceRevision: row.derivedTextRevision,
                appendBaseRevision: derived.displayAppendBaseRevision,
                appendedDisplaySuffix: derived.displayAppendSuffix, to: storage)
        }
        render(first)
        var stableIdentity = true, immediate = true
        for index in 0..<200 {
            let delta = "片段 \(index) 🧑‍💻\n"
            expected += delta
            emit(delta)
            guard let row = engine.transcript(for: thread).last else { return false }
            stableIdentity = stableIdentity && row.id == first.id
            render(row)
            immediate = immediate && row.text == expected
                && storage.string == expected.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let metrics = cache.metricsSnapshot()
        check("all deltas update the same visible row", stableIdentity && engine.transcript(for: thread).count == 1)
        check("every delta renders immediately and exactly", immediate)
        check("view receives changes before the turn ends", notifications >= 201)
        check("derived cache computes the full source once", metrics.fullComputations == 1)
        check("derived cache reuses all 200 append deltas", metrics.incrementalComputations == 200)
        check("incremental path avoids whole-display rehash", metrics.incrementalWholeDisplayRehashes == 0)
        check("text storage replaces the full payload once", controller.metrics.fullAttributedReplacements == 1)
        check("text storage appends all 200 suffixes", controller.metrics.incrementalAttributedAppends == 200)
        check("streaming row remains writing before result", engine.transcript(for: thread).last?.status?.hasPrefix("writing") == true)
        let notificationCount = notifications
        engine.handleSDK(thread, ["type": "stream_event", "client_turn_id": "retired-fixture-turn",
            "event": ["type": "content_block_delta", "delta": ["type": "text_delta", "text": "STALE"]]])
        engine.handleSDK(thread, ["type": "result", "client_turn_id": "retired-fixture-turn",
            "is_error": true, "result": "STALE"])
        check("retired tagged text and result cannot mutate the transcript",
              engine.transcript(for: thread).count == 1 && engine.transcript(for: thread).last?.text == expected)
        check("retired completion does not end another streaming row",
              engine.transcript(for: thread).last?.status?.hasPrefix("writing") == true)
        check("retired events do not trigger liveness or UI updates", notifications == notificationCount)
        let appendMetrics = controller.metrics
        var rewriteMatchesFull = true
        for delta in ["\n<oai-mem-citation>\n", "fixture-reference\n", "</oai-mem-citation>\n"] {
            expected += delta
            emit(delta)
            guard let row = engine.transcript(for: thread).last else { return false }
            render(row)
            let reference = row.derivedSnapshot(using: ChatMessageDerivedValueCache())
            rewriteMatchesFull = rewriteMatchesFull && storage.string == reference.transcriptDisplayText
        }
        check("projection-changing deltas match a fresh full parse", rewriteMatchesFull)
        check("hidden trailing citation is removed from rendered storage", !storage.string.contains("fixture-reference"))
        check("real rewrite uses safe replacement rather than stale append", controller.metrics.fullAttributedReplacements > appendMetrics.fullAttributedReplacements)
        engine.handleSDK(thread, ["type": "result", "is_error": false])
        check("terminal event retains exact final text", engine.transcript(for: thread).last?.text == expected)
        check("terminal event marks the row done", engine.transcript(for: thread).last?.status == "done")
        check("final text survives store reload", store.load().threads.first(where: { $0.id == thread })?.messages.last?.text == expected)
        check("fixture never starts a native model", engine.sidecarProcessID(threadID: thread) == nil)
        let cases: [(String, [String])] = [
            ("split markdown", ["正文\n", "**粗", "體**\n", "- item", "\n"]),
            ("split CRLF and blanks", ["正文\r", "\n", "\r", "\n第二行", "\r", "\n"]),
            ("combining unicode", ["正文 e", "\u{301}", " 👩", "\u{200D}", "💻", "\n"]),
            ("streamed code fences", ["正文\n", "```swift\n", "let x = 1", "\n", "```", "\n結束"]),
            ("attachment line", ["正文\n", "![圖]", "(/fixture/image.png)", "\n下一行"]),
            ("whitespace transitions", ["  正文   ", "\n", "  ", "\n下一行", "   ", "\n"])
        ]
        for (name, deltas) in cases {
            var row = ChatMessage(role: .assistant, text: "", status: "writing|回覆中")
            let corpusCache = ChatMessageDerivedValueCache()
            let corpusController = ChatStreamingPlainTextStorageController()
            let corpusStorage = NSTextStorage()
            let corpusIdentity = ChatTranscriptPresentationIdentity(messageID: row.id,
                parserVersion: TatwoAssistantTranscriptCache.defaultParserVersion, sessionBoundaryGeneration: 1)
            var matches = true
            for delta in deltas {
                row.appendTranscriptText(delta)
                let value = row.derivedSnapshot(using: corpusCache)
                let reference = row.derivedSnapshot(using: ChatMessageDerivedValueCache())
                corpusController.apply(text: value.transcriptDisplayText, fingerprint: value.transcriptDisplayFingerprint,
                    presentationIdentity: corpusIdentity, sourceRevision: row.derivedTextRevision,
                    appendBaseRevision: value.displayAppendBaseRevision,
                    appendedDisplaySuffix: value.displayAppendSuffix, to: corpusStorage)
                matches = matches && value == reference && corpusStorage.string == reference.transcriptDisplayText
            }
            check("fresh-parse parity: \(name)", matches)
        }
        // Reproduce the user's numbered CJK response through both production paths.
        let numberedText = (44...80).map {
            "第 \($0) 行：這是連續輸出與捲動驗收文字"
        }.joined(separator: "\n")
        let numberedStorage = NSTextStorage()
        let numberedController = ChatStreamingPlainTextStorageController()
        let numberedCache = ChatMessageDerivedValueCache()
        var numberedRow = ChatMessage(role: .assistant, text: "", status: "writing|回覆中")
        let numberedIdentity = ChatTranscriptPresentationIdentity(messageID: numberedRow.id,
            parserVersion: TatwoAssistantTranscriptCache.defaultParserVersion, sessionBoundaryGeneration: 1)
        for line in numberedText.components(separatedBy: "\n") {
            numberedRow.appendTranscriptText((numberedRow.text.isEmpty ? "" : "\n") + line)
            let value = numberedRow.derivedSnapshot(using: numberedCache)
            numberedController.apply(text: value.transcriptDisplayText, fingerprint: value.transcriptDisplayFingerprint,
                presentationIdentity: numberedIdentity, sourceRevision: numberedRow.derivedTextRevision,
                appendBaseRevision: value.displayAppendBaseRevision,
                appendedDisplaySuffix: value.displayAppendSuffix, to: numberedStorage)
        }
        let plain = ChatTranscriptFlowComposer.plainAttributedText(numberedText)
        let block = TatwoAssistantTranscriptBlock(id: .init(contentHash: 1, occurrence: 0),
            kind: .paragraph, content: AttributedString(numberedText))
        let completed = ChatTranscriptFlowComposer.attributedPayload(blocks: [block], previousKind: nil).attributed
        // NSTextStorage fixes the first CJK character to its fallback font.
        // Compare the digit's font, not that unrelated fallback run.
        let streamingFont = numberedStorage.attribute(.font, at: 2, effectiveRange: nil) as! NSFont
        let completedFont = completed.attribute(.font, at: 2, effectiveRange: nil) as! NSFont
        let plainFont = plain.attribute(.font, at: 2, effectiveRange: nil) as! NSFont
        let oldFont = NSFont.systemFont(ofSize: TatwoChatTranscriptVisualMetrics.transcriptPointSize)
        func suffixOffsets(_ font: NSFont) -> [CGFloat] {
            (44...80).map { number in
                let prefix = "第 \(number) 行："
                let line = CTLineCreateWithAttributedString(NSAttributedString(
                    string: prefix + "這是連續輸出與捲動驗收文字", attributes: [.font: font]))
                return CTLineGetOffsetForStringIndex(line, (prefix as NSString).length, nil)
            }
        }
        func actualSuffixOffsets(_ payload: NSAttributedString) -> [CGFloat] {
            let text = payload.string as NSString
            var offsets: [CGFloat] = []
            var start = 0
            while start < text.length {
                let range = text.lineRange(for: NSRange(location: start, length: 0))
                let row = payload.attributedSubstring(from: range)
                let suffix = (row.string as NSString).range(of: "這")
                if suffix.location != NSNotFound {
                    let line = CTLineCreateWithAttributedString(row)
                    offsets.append(CTLineGetOffsetForStringIndex(line, suffix.location, nil))
                }
                start = NSMaxRange(range)
            }
            return offsets
        }
        func spread(_ offsets: [CGFloat]) -> CGFloat { offsets.max()! - offsets.min()! }
        print("STREAMAPPENDTEST OLD_DIGIT_SPREAD \(spread(suffixOffsets(oldFont)))")
        check("streamed numbered lines preserve original text", numberedStorage.string == numberedText)
        check("completed paragraph preserves original text", completed.string == numberedText)
        check("plain paragraph preserves original text", plain.string == numberedText)
        check("streaming and completed fonts agree", streamingFont == completedFont && completedFont == plainFont)
        let streamOffsets = actualSuffixOffsets(numberedStorage)
        let completedOffsets = actualSuffixOffsets(completed)
        check("all same-length numeric prefixes align in streaming", streamOffsets.count == 37 && spread(streamOffsets) < 0.01)
        check("all same-length numeric prefixes align after completion", completedOffsets.count == 37 && spread(completedOffsets) < 0.01)
        check("body size is unchanged", streamingFont.pointSize == oldFont.pointSize)
        let body = "這是連續輸出與捲動驗收文字"
        check("CJK advance is unchanged",
            abs((body as NSString).size(withAttributes: [.font: oldFont]).width
                - (body as NSString).size(withAttributes: [.font: streamingFont]).width) < 0.01)
        let streamStyle = numberedStorage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as! NSParagraphStyle
        let completedStyle = completed.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as! NSParagraphStyle
        check("stream and completed line spacing stays unchanged",
            streamStyle.lineSpacing == TatwoChatTranscriptVisualMetrics.transcriptLineSpacing
                && completedStyle.lineSpacing == streamStyle.lineSpacing)
        let before = NSMutableAttributedString(attributedString: plain)
        before.addAttribute(.font, value: oldFont, range: NSRange(location: 0, length: before.length))
        for (name, payload) in [("digits-before", before as NSAttributedString),
                                ("digits-streaming", numberedStorage as NSAttributedString),
                                ("digits-completed", completed)] {
            let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 760))
            view.appearance = NSAppearance(named: .aqua)
            view.textContainerInset = NSSize(width: 8, height: 8)
            view.textStorage?.setAttributedString(payload)
            view.layoutManager?.ensureLayout(for: view.textContainer!)
            if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let data = bitmap.representation(using: .png, properties: [:])
                do {
                    try data?.write(to: root.appendingPathComponent(name + ".png"))
                    check("\(name) native text fixture captured", data != nil)
                } catch {
                    check("\(name) native text fixture captured", false)
                }
            } else {
                check("\(name) native text fixture captured", false)
            }
        }
        print("STREAMAPPENDTEST APPEND_METRICS full=\(metrics.fullComputations) incremental=\(metrics.incrementalComputations) storageReplace=\(appendMetrics.fullAttributedReplacements) storageAppend=\(appendMetrics.incrementalAttributedAppends)")
        print("STREAMAPPENDTEST RESULT passed=\(passed) failed=\(failed) skipped=0")
        return failed == 0
    }
}
