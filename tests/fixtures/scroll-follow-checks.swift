import Foundation

@main
struct ScrollFollowChecks {
    static func main() {
        var failed = 0, passed = 0
        func check(_ name: String, _ success: Bool) {
            if success { passed += 1 } else { failed += 1 }
            print("SCROLLFOLLOWTEST \(success ? "PASS" : "FAIL") \(name)")
        }
        var state = ChatTranscriptScrollFollowState()
        check("new transcript follows latest", state.shouldAutoScrollOnContentChange)
        state.update(bottomY: 900, viewportHeight: 500)
        check("long initial layout cannot cancel first positioning", state.shouldAutoScrollOnContentChange)
        state.detachFromLatest()
        check("reading history shows return control", state.showsJumpToLatest)
        state.update(bottomY: 0, viewportHeight: 500)
        check("missing sentinel cannot reattach", !state.shouldAutoScrollOnContentChange)
        state.update(bottomY: 300, viewportHeight: 0)
        check("missing viewport cannot reattach", !state.shouldAutoScrollOnContentChange)
        state.update(bottomY: .nan, viewportHeight: 500)
        check("invalid geometry cannot reattach", !state.shouldAutoScrollOnContentChange)
        state.update(bottomY: 500, viewportHeight: .infinity)
        check("infinite geometry cannot reattach", !state.shouldAutoScrollOnContentChange)
        state.update(bottomY: 570, viewportHeight: 500)
        check("layout near bottom is not a return gesture", !state.shouldAutoScrollOnContentChange)
        state.detachFromLatest()
        check("explicit history navigation cancels pending follow", !state.shouldAutoScrollOnContentChange)
        state.update(bottomY: 510, viewportHeight: 500)
        check("near-bottom layout cannot override user intent", !state.shouldAutoScrollOnContentChange)
        state.update(bottomY: 500, viewportHeight: 500)
        check("shorter streamed content cannot override user intent", !state.shouldAutoScrollOnContentChange)
        for offset in 0..<1000 { state.update(bottomY: CGFloat(500 + offset % 80), viewportHeight: 500) }
        check("repeated streaming reflow remains detached", !state.shouldAutoScrollOnContentChange)
        state.update(bottomY: 0, viewportHeight: 500)
        check("history intent survives lazy row replacement", !state.shouldAutoScrollOnContentChange)
        state.jumpToLatest()
        check("explicit latest control resumes following", state.shouldAutoScrollOnContentChange)
        state.update(bottomY: 580, viewportHeight: 500)
        check("existing 80 point threshold retained", state.shouldAutoScrollOnContentChange)
        state.update(bottomY: 581, viewportHeight: 500)
        check("large streamed block preserves active following", state.shouldAutoScrollOnContentChange)
        check("new conversation starts following independently", ChatTranscriptScrollFollowState().shouldAutoScrollOnContentChange)
        print("SCROLLFOLLOWTEST RESULT passed=\(passed) failed=\(failed) skipped=0")
        if failed > 0 { fatalError("scroll-follow regression") }
    }
}
