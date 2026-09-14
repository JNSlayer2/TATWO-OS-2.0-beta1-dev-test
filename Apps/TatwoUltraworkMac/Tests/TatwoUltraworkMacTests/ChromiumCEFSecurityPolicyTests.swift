import Foundation
import ObjectiveC
import TatwoCEFBridge
import XCTest

@testable import TatwoUltraworkMac

@MainActor
final class ChromiumCEFSecurityPolicyTests: XCTestCase {
    func testNativeClickNeverTruncatesFractionalOrOutOfRangeCoordinates() throws {
        // Source contract only; this does not synthesize or verify native input.
        let source = try bridgeSource()
        let start = try XCTUnwrap(source.range(of: "- (BOOL)sendClickAtPoint:"))
        let end = try XCTUnwrap(source.range(of: "- (void)clickElement:",
            range: start.upperBound..<source.endIndex))
        let body = String(source[start.lowerBound..<end.lowerBound])
        let conversion = try XCTUnwrap(body.range(of: "event.x = static_cast<int>(point.x)"))
        for check in [
            "BrowserInputIsCurrent(self, generation)",
            "!std::isfinite(point.x)", "!std::isfinite(point.y)",
            "point.x != std::floor(point.x)", "point.y != std::floor(point.y)",
            "point.x > std::numeric_limits<int>::max()",
            "point.y > std::numeric_limits<int>::max()",
            "point.x >= self.bounds.size.width", "point.y >= self.bounds.size.height",
        ] {
            let range = try XCTUnwrap(body.range(of: check))
            XCTAssertLessThan(range.lowerBound, conversion.lowerBound)
        }
        XCTAssertTrue(body.contains("host->SendMouseClickEvent(event, MBT_LEFT, false, 1)"))
        XCTAssertTrue(body.contains("host->SendMouseClickEvent(event, MBT_LEFT, true, 1)"))
    }

    func testAgentClickSharesTheBoundedNodeInputSlot() throws {
        // Source contracts only. None of these tests proves real CEF input,
        // shadow-root behavior, coordinate fidelity, or stop latency.
        let source = try bridgeSource()
        let textStart = try XCTUnwrap(source.range(of: "void TatwoClient::TypeText("))
        let clickStart = try XCTUnwrap(source.range(of: "void TatwoClient::ClickElement(",
            range: textStart.upperBound..<source.endIndex))
        let begin = try XCTUnwrap(source.range(of: "void TatwoClient::BeginNodeInput(",
            range: clickStart.upperBound..<source.endIndex))
        let end = try XCTUnwrap(source.range(of: "BOOL TatwoClient::DispatchCheckedClick(",
            range: begin.upperBound..<source.endIndex))
        let text = String(source[textStart.lowerBound..<clickStart.lowerBound])
        let click = String(source[clickStart.lowerBound..<begin.lowerBound])
        let shared = String(source[begin.lowerBound..<end.lowerBound])
        XCTAssertTrue(text.contains("NodeInputKind::text, text, submit"))
        XCTAssertTrue(click.contains("NodeInputKind::click, nil, false"))
        XCTAssertTrue(shared.contains("type_completion_ != nil"))
        XCTAssertTrue(shared.contains("snapshot_completion_ != nil"))
        XCTAssertTrue(shared.contains("dispatch_gate == nil"))
        XCTAssertTrue(shared.contains("type_dispatch_gate_ = [dispatch_gate copy]"))
        XCTAssertTrue(shared.contains("10 * NSEC_PER_SEC"))
        XCTAssertTrue(shared.contains("type_request_serial_ == serial"))
        let geometry = try XCTUnwrap(shared.range(of: "if (kind == NodeInputKind::click"))
        let observer = try XCTUnwrap(shared.range(of: "AddDevToolsMessageObserver("))
        let retained = try XCTUnwrap(shared.range(of: "type_completion_ = [completion copy]"))
        XCTAssertLessThan(geometry.lowerBound, observer.lowerBound)
        XCTAssertLessThan(observer.lowerBound, retained.lowerBound)
        XCTAssertFalse(click.contains("sendClickAtPoint:"))
    }

    func testAgentClickConvertsDocumentLookupAndReprobesExactNativePoint() throws {
        let source = try bridgeSource()
        let start = try XCTUnwrap(source.range(of: "if (type_stage_ == TypeStage::readingClickMetrics"))
        let end = try XCTUnwrap(source.range(of: "if (type_stage_ == TypeStage::locatingHit",
            range: start.upperBound..<source.endIndex))
        let body = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(source.contains(#"DispatchTypeCommand(browser, "Page.getLayoutMetrics", params)"#))
        for check in [
            #"parsed[@"cssVisualViewport"]"#,
            #"@[@"pageX", @"pageY", @"offsetX", @"offsetY", @"scale"]"#,
            "CFBooleanGetTypeID()", "!std::isfinite([value doubleValue])",
            "metrics[2] != 0 || metrics[3] != 0 || metrics[4] != 1",
            "std::round(type_click_point_.x + metrics[0])",
            "std::round(type_click_point_.y + metrics[1])",
            "document_x < std::numeric_limits<int>::min()",
            "document_y > std::numeric_limits<int>::max()",
        ] {
            XCTAssertTrue(body.contains(check), check)
        }
        let guardRange = try XCTUnwrap(body.range(of: "!std::isfinite(document_x)"))
        let conversion = try XCTUnwrap(body.range(of: #"params->SetInt("x", static_cast<int>(document_x))"#))
        XCTAssertLessThan(guardRange.lowerBound, conversion.lowerBound)
        XCTAssertTrue(body.contains(#"params->SetInt("y", static_cast<int>(document_y))"#))
        XCTAssertTrue(body.contains(#"params->SetBool("includeUserAgentShadowDOM", true)"#))
        XCTAssertTrue(body.contains(#"params->SetBool("ignorePointerEventsNone", false)"#))
        XCTAssertFalse(body.contains(#"parsed[@"visualViewport"]"#))
        XCTAssertFalse(body.contains("static_cast<int>(type_click_point_"))
    }

    func testAgentClickResolvesTargetAndHitInTheSameIsolatedContext() throws {
        let source = try bridgeSource()
        let start = try XCTUnwrap(source.range(of: "if (type_stage_ == TypeStage::locatingHit"))
        let resolve = try XCTUnwrap(source.range(of: "if (type_stage_ == TypeStage::resolvingHit",
            range: start.upperBound..<source.endIndex))
        let end = try XCTUnwrap(source.range(of: "if (type_stage_ == TypeStage::checkingClick",
            range: resolve.upperBound..<source.endIndex))
        let location = String(source[start.lowerBound..<resolve.lowerBound])
        let probe = String(source[resolve.lowerBound..<end.lowerBound])
        for check in [
            "isKindOfClass:NSNumber.class", "CFBooleanGetTypeID()",
            "!std::isfinite([hit_id doubleValue])", "[hit_id doubleValue] <= 0",
            "[hit_id doubleValue] > std::numeric_limits<int>::max()",
            "std::floor([hit_id doubleValue]) != [hit_id doubleValue]",
            #"![parsed[@"frameId"] isEqual:type_frame_id_]"#,
        ] {
            let validation = try XCTUnwrap(location.range(of: check))
            let conversion = try XCTUnwrap(location.range(of: "[hit_id intValue]"))
            XCTAssertLessThan(validation.lowerBound, conversion.lowerBound)
        }
        XCTAssertTrue(source.contains("type_context_id_ = static_cast<int>(context_id)"))
        XCTAssertTrue(source.contains("type_target_object_id_ = [object_id copy]"))
        XCTAssertTrue(location.contains(#"params->SetInt("executionContextId", type_context_id_)"#))
        XCTAssertTrue(location.contains(#"params->SetString("objectGroup", ToCefString(type_object_group_))"#))
        XCTAssertTrue(location.contains(#"DispatchTypeCommand(browser, "DOM.resolveNode", params)"#))
        XCTAssertTrue(probe.contains(#"params->SetString("objectId", ToCefString(type_target_object_id_))"#))
        XCTAssertTrue(probe.contains(#"hit->SetString("objectId", ToCefString(object_id))"#))
        XCTAssertTrue(probe.contains("arguments->SetDictionary(0, hit)"))
        XCTAssertTrue(probe.contains("{type_click_point_.x, type_click_point_.y, 0, 0}"))
        XCTAssertTrue(probe.contains(#"params->SetString("functionDeclaration", kTatwoCheckClickNode)"#))
        XCTAssertTrue(probe.contains(#"DispatchTypeCommand(browser, "Runtime.callFunctionOn", params)"#))
        XCTAssertFalse(location.contains("ExecuteDevToolsMethod("))
        XCTAssertFalse(probe.contains("ExecuteDevToolsMethod("))
    }

    func testAgentClickProbeRejectsOcclusionAndNestedActionableControls() throws {
        let source = try bridgeSource()
        let start = try XCTUnwrap(source.range(of: "static const char kTatwoCheckClickNode[]"))
        let end = try XCTUnwrap(source.range(of: ")TATWOJS\";",
            range: start.upperBound..<source.endIndex))
        let script = String(source[start.lowerBound..<end.lowerBound])
        for check in [
            "window.top !== window", "location.href !== expectedURL",
            "target.ownerDocument !== document", "hit.ownerDocument !== document",
            "!target.isConnected", "!hit.isConnected",
            "Math.abs(value-rect[i]) > 1/64", "point[0] >= Math.min(innerWidth,current.right)",
            "node.assignedSlot || node.parentElement", "node.getRootNode().host",
            "node === target", "if (!reached) return false",
            "a[href],button,input,textarea,select,summary,label", "node.isContentEditable",
            "opacity*=Number(style.opacity)", "!Number.isFinite(opacity) || opacity < 0.1",
            "node=parent(target)", "Document.prototype.elementFromPoint",
            "ShadowRoot.prototype.elementFromPoint",
            "probe.call(root,point[0],point[1]) !== node",
            "visualViewport.scale !== 1", "depth<64",
        ] {
            XCTAssertTrue(script.contains(check), check)
        }
        for sideEffect in [".click(", ".focus(", "dispatchEvent(", "requestSubmit(", "new MouseEvent("] {
            XCTAssertFalse(script.contains(sideEffect), sideEffect)
        }
    }

    func testAgentClickFinalNativeDispatchReusesTheOriginalGate() throws {
        let source = try bridgeSource()
        let start = try XCTUnwrap(source.range(of: "BOOL TatwoClient::DispatchCheckedClick("))
        let end = try XCTUnwrap(source.range(of: "void TatwoClient::OnTypeTextResult(",
            range: start.upperBound..<source.endIndex))
        let body = String(source[start.lowerBound..<end.lowerBound])
        let gate = try XCTUnwrap(body.range(of: "const BOOL authorized = gate("))
        let input = try XCTUnwrap(body.range(of: "[owner sendClickAtPoint:point navigationGeneration:generation]"))
        let closed = try XCTUnwrap(body.range(of: "accepting = NO"))
        XCTAssertTrue(body.contains("TatwoCEFBrowserInputDispatchGate gate = type_dispatch_gate_"))
        XCTAssertLessThan(gate.lowerBound, input.lowerBound)
        XCTAssertLessThan(input.lowerBound, closed.lowerBound)
        for check in [
            "!NSThread.isMainThread || !accepting || invoked",
            "BrowserInputIsCurrent(owner, generation)",
            "state->client.get() != original_client", "state->client->type_completion_ == nil",
            "state->client->type_request_serial_ != serial",
            "state->client->type_kind_ != NodeInputKind::click",
            "state->client->type_stage_ != TypeStage::dispatchingClick",
            "state->browser->IsSame(browser)",
            "![state->committed_url isEqualToString:expected_url]",
            "!NSEqualSizes(owner.bounds.size, viewport)", "GetZoomLevel() != 0",
        ] {
            let validation = try XCTUnwrap(body.range(of: check))
            XCTAssertLessThan(gate.lowerBound, validation.lowerBound)
            XCTAssertLessThan(validation.lowerBound, input.lowerBound)
        }
        XCTAssertTrue(body.contains("return authorized && sent"))
        let check = try XCTUnwrap(source.range(of: "if (type_stage_ == TypeStage::checkingClick"))
        let resultEnd = try XCTUnwrap(source.range(of: "if (type_stage_ != TypeStage::applyingText",
            range: check.upperBound..<source.endIndex))
        let result = String(source[check.lowerBound..<resultEnd.lowerBound])
        let validation = try XCTUnwrap(result.range(of: #"![value[@"value"] isEqual:@YES]"#))
        let dispatch = try XCTUnwrap(result.range(of: "DispatchCheckedClick(browser)"))
        XCTAssertLessThan(validation.lowerBound, dispatch.lowerBound)
        XCTAssertTrue(result.contains(#"parsed[@"exceptionDetails"] != nil"#))
        XCTAssertTrue(result.contains(#"![value[@"type"] isEqual:@"boolean"]"#))
    }

    func testAgentClickUsesNativeFlatTreeVisibilityBeforeGeometryAndRetargeting() throws {
        // Source only: this does not execute Blink, a closed slot, or a click.
        let source = try bridgeSource()
        let start = try XCTUnwrap(source.range(of: "static const char kTatwoCheckClickNode[]"))
        let end = try XCTUnwrap(source.range(of: ")TATWOJS\";",
            range: start.upperBound..<source.endIndex))
        let script = String(source[start.lowerBound..<end.lowerBound])
        let binding = try XCTUnwrap(script.range(of: "const nativeVisibility = Element.prototype.checkVisibility"))
        let required = try XCTUnwrap(script.range(of: "if (typeof nativeVisibility !== 'function') return false"))
        let target = try XCTUnwrap(script.range(of: "nativeVisibility.call(target,visibilityOptions) !== true"))
        let hit = try XCTUnwrap(script.range(of: "hit !== target && nativeVisibility.call(hit,visibilityOptions) !== true"))
        let geometry = try XCTUnwrap(script.range(of: "Element.prototype.getBoundingClientRect.call(target)"))
        let retarget = try XCTUnwrap(script.range(of: "probe.call(root,point[0],point[1]) !== node"))
        XCTAssertLessThan(binding.lowerBound, required.lowerBound)
        XCTAssertLessThan(required.lowerBound, target.lowerBound)
        XCTAssertLessThan(target.lowerBound, hit.lowerBound)
        XCTAssertLessThan(hit.lowerBound, geometry.lowerBound)
        XCTAssertLessThan(geometry.lowerBound, retarget.lowerBound)
        // Pinned Blink's older option names are checked even when the extra
        // properties feature is off. Zero-opacity checks do not replace the
        // separate cumulative opacity and exact-point occlusion checks.
        XCTAssertTrue(script.contains("checkOpacity:true, checkVisibilityCSS:true, contentVisibilityAuto:true"))
        XCTAssertTrue(script.contains("opacity*=Number(style.opacity)"))
        XCTAssertTrue(script.contains("!Number.isFinite(opacity) || opacity < 0.1"))
        XCTAssertFalse(script.contains(".click("))
        XCTAssertFalse(script.contains("dispatchEvent("))
    }

    func testAgentClickSharedDispatchAndCleanupRetainActionIdentity() throws {
        let source = try bridgeSource()
        let dispatchStart = try XCTUnwrap(source.range(of: "int TatwoClient::DispatchTypeCommand("))
        let dispatchEnd = try XCTUnwrap(source.range(of: "void TatwoClient::TypeText(",
            range: dispatchStart.upperBound..<source.endIndex))
        let dispatch = String(source[dispatchStart.lowerBound..<dispatchEnd.lowerBound])
        XCTAssertTrue(dispatch.contains("const NodeInputKind kind = type_kind_"))
        let kind = try XCTUnwrap(dispatch.range(of: "state->client->type_kind_ != kind"))
        let enqueue = try XCTUnwrap(dispatch.range(of: "ExecuteDevToolsMethod("))
        XCTAssertLessThan(kind.lowerBound, enqueue.lowerBound)
        let start = try XCTUnwrap(source.range(of: "void TatwoClient::FinishTypeText("))
        let end = try XCTUnwrap(source.range(of: "void TatwoClient::CaptureVisibleSnapshot(",
            range: start.upperBound..<source.endIndex))
        let body = String(source[start.lowerBound..<end.lowerBound])
        let callback = try XCTUnwrap(body.range(of: "if (completion) completion("))
        for reset in [
            "type_frame_id_ = nil", "type_target_object_id_ = nil", "type_context_id_ = 0",
            "type_kind_ = NodeInputKind::text", "type_stage_ = TypeStage::idle",
            "type_click_point_ = NSZeroPoint", "type_click_rect_ = NSZeroRect",
            "type_click_viewport_ = NSZeroSize", "type_dispatch_gate_ = nil",
        ] {
            let position = try XCTUnwrap(body.range(of: reset))
            XCTAssertLessThan(position.lowerBound, callback.lowerBound)
        }
        XCTAssertTrue(body.contains("state->browser->IsSame(original_browser)"))
    }

    func testUnavailableAgentClickNeverInvokesTheGate() throws {
        let source = try source(relativePath: "Sources/TatwoCEFBridge/TatwoCEFBridgeUnavailable.m")
        let start = try XCTUnwrap(source.range(of: "- (void)clickElement:"))
        let end = try XCTUnwrap(source.range(of: "- (BOOL)sendScrollDeltaY:",
            range: start.upperBound..<source.endIndex))
        let body = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(body.contains("dispatchGate:(TatwoCEFBrowserInputDispatchGate)dispatchGate"))
        XCTAssertTrue(body.contains(#"completion(NO, @"browser_unavailable")"#))
        XCTAssertFalse(body.contains("dispatchGate("))
        XCTAssertFalse(body.contains("sendClickAtPoint:"))
        let header = try self.source(relativePath: "Sources/TatwoCEFBridge/include/TatwoCEFBridge.h")
        XCTAssertTrue(header.contains("clickElement(_:at:expectedRect:viewportSize:navigationGeneration:dispatchGate:completion:)"))
    }

    func testAgentClickSwiftWrapperRetainsTheRequestWithoutAnOuterInputLock() throws {
        let source = try source(relativePath: "../../App/Sources/Tatwo2/Facade/BrowserAgentBridge.swift")
        let start = try XCTUnwrap(source.range(of: "private func click(elementID:"))
        let end = try XCTUnwrap(source.range(of: "private func typeText(",
            range: start.upperBound..<source.endIndex))
        let body = String(source[start.lowerBound..<end.lowerBound])
        let native = try XCTUnwrap(body.range(of: "bound.view.clickElement(elementID"))
        let gate = try XCTUnwrap(body.range(of: "dispatchGate: { dispatch in"))
        let enqueue = try XCTUnwrap(body.range(of: "self.enqueueBrowserInput(request) { dispatch() }"))
        let callback = try XCTUnwrap(body.range(of: "}) { completed, error in"))
        XCTAssertLessThan(native.lowerBound, gate.lowerBound)
        XCTAssertLessThan(gate.lowerBound, enqueue.lowerBound)
        XCTAssertLessThan(enqueue.lowerBound, callback.lowerBound)
        XCTAssertNotNil(body.range(of: "self.validateCEFBinding(bound, request: request)",
            range: gate.upperBound..<enqueue.lowerBound))
        XCTAssertTrue(body.contains("semaphore.wait(timeout: .now() + 15)"))
        XCTAssertTrue(body.contains("self.activeBrowserView(request) === bound.view"))
        XCTAssertFalse(body.contains(".sendClick("))
        // A delivered click may have navigated already. Do not retry or demand
        // the pre-click URL when reporting an acknowledgement needing readback.
        let completion = String(body[callback.lowerBound...])
        XCTAssertTrue(completion.contains("self.checkedOnMain(request)"))
        XCTAssertFalse(completion.contains("self.validateCEFBinding("))
        XCTAssertFalse(completion.contains("bound.view.clickElement("))
    }

    func testNativeNavigationRetainsAndConsumesURLGatePairs() throws {
        // Source-contract coverage, not native execution or stop-latency proof.
        let source = try bridgeSource()
        XCTAssertTrue(source.contains("TatwoCEFBrowserInputDispatchGate pending_navigation_gate"))
        let startup = try XCTUnwrap(source.range(of: "- (void)startBrowserIfReady {"))
        let layout = try XCTUnwrap(source.range(of: "- (void)layout {", range: startup.upperBound..<source.endIndex))
        let creation = String(source[startup.lowerBound..<layout.lowerBound])
        XCTAssertTrue(creation.contains("[state->pending_navigation_gate copy]"))
        XCTAssertTrue(creation.contains("state->pending_navigation_gate = nil"))
        let gate = try XCTUnwrap(creation.range(of: "DispatchBrowserNavigation(self, creation_gate"))
        let factory = try XCTUnwrap(creation.range(of: "CefBrowserHost::CreateBrowser("))
        XCTAssertLessThan(gate.lowerBound, factory.lowerBound)
        XCTAssertFalse(creation.contains("CreateBrowserSync("))

        let after = try XCTUnwrap(source.range(of: "void TatwoClient::OnAfterCreated"))
        let close = try XCTUnwrap(source.range(of: "bool TatwoClient::DoClose", range: after.upperBound..<source.endIndex))
        let pending = String(source[after.lowerBound..<close.lowerBound])
        XCTAssertTrue(pending.contains("[state->pending_navigation_gate copy]"))
        XCTAssertTrue(pending.contains("state->pending_navigation_gate = nil"))
        let pendingGate = try XCTUnwrap(pending.range(of: "DispatchBrowserNavigation(owner, pending_gate"))
        let pendingLoad = try XCTUnwrap(pending.range(of: "browser->GetMainFrame()->LoadURL("))
        XCTAssertLessThan(pendingGate.lowerBound, pendingLoad.lowerBound)
        XCTAssertTrue(source.contains("state->pending_navigation_gate = [dispatchGate copy]"))
        XCTAssertTrue(source.contains("state->close_requested = true;\n  state->pending_url = nil;\n  state->pending_navigation_gate = nil;"))
    }

    func testNativeNavigationGateRejectsLateDuplicateAndReplacedTargets() throws {
        let source = try bridgeSource()
        let start = try XCTUnwrap(source.range(of: "BOOL DispatchBrowserNavigation("))
        let end = try XCTUnwrap(source.range(of: "int TatwoClient::DispatchTypeCommand(",
            range: start.upperBound..<source.endIndex))
        let body = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(body.contains("!NSThread.isMainThread || !accepting || invoked"))
        XCTAssertTrue(body.contains("state != original_state"))
        XCTAssertTrue(body.contains("state->mount_generation != mount_generation"))
        XCTAssertTrue(body.contains("state->browser->IsSame(original_browser)"))
        XCTAssertTrue(body.contains("owner.isHiddenOrHasHiddenAncestor"))
        XCTAssertTrue(body.contains("state->close_requested"))
        let preflight = try XCTUnwrap(body.range(of: "if (!is_current()) return NO"))
        let gate = try XCTUnwrap(body.range(of: "const BOOL authorized = gate("))
        let inlineCheck = try XCTUnwrap(body.range(of: "if (!is_current()) return;"))
        let finished = try XCTUnwrap(body.range(of: "accepting = NO"))
        XCTAssertLessThan(preflight.lowerBound, gate.lowerBound)
        XCTAssertLessThan(gate.lowerBound, inlineCheck.lowerBound)
        XCTAssertLessThan(inlineCheck.lowerBound, finished.lowerBound)
    }

    func testUnavailableNavigationNeverInvokesTheAgentGate() throws {
        let source = try source(relativePath: "Sources/TatwoCEFBridge/TatwoCEFBridgeUnavailable.m")
        let start = try XCTUnwrap(source.range(of: "- (void)loadURLString:(NSString *)urlString\n        dispatchGate:"))
        let end = try XCTUnwrap(source.range(of: "- (void)goBack",
            range: start.upperBound..<source.endIndex))
        let body = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertFalse(body.contains("dispatchGate("))
        XCTAssertFalse(body.contains("dispatch()"))
    }

    func testInertStartupExceptionDoesNotRelaxPublicURLPolicy() throws {
        let source = try bridgeSource()
        XCTAssertEqual(source.components(separatedBy:
            #"const bool initial_blank = [initialURL isEqualToString:@"about:blank"]"#).count - 1, 2)
        let start = try XCTUnwrap(source.range(of: "bool IsAllowedURLString("))
        let end = try XCTUnwrap(source.range(of: "bool SocketAddressIsPrivate(",
            range: start.upperBound..<source.endIndex))
        let policy = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertFalse(policy.contains("about:blank"))
        XCTAssertTrue(policy.contains(#"![scheme isEqualToString:@"http"]"#))
        XCTAssertTrue(policy.contains(#"![scheme isEqualToString:@"https"]"#))
        XCTAssertTrue(source.contains("if (dispatchGate == nil) return;"))
    }

    func testNativeTextStagesUseTheRetainedDispatchGate() throws {
        // Source-contract coverage only; not a native stop-timing test.
        let source = try bridgeSource()
        let start = try XCTUnwrap(source.range(of: "void TatwoClient::TypeText("))
        let end = try XCTUnwrap(source.range(of: "void TatwoClient::FinishTypeText(",
            range: start.upperBound..<source.endIndex))
        let stages = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(stages.contains("dispatch_gate == nil"))
        XCTAssertTrue(stages.contains("type_dispatch_gate_ = [dispatch_gate copy]"))
        XCTAssertTrue(stages.contains(#"DispatchTypeCommand(browser, "DOM.resolveNode", params)"#))
        XCTAssertTrue(stages.contains(#"DispatchTypeCommand(browser, "Runtime.callFunctionOn", params)"#))
        XCTAssertFalse(stages.contains("ExecuteDevToolsMethod("))

        let cleanupEnd = try XCTUnwrap(source.range(of: "void TatwoClient::CaptureVisibleSnapshot(",
            range: end.upperBound..<source.endIndex))
        let cleanup = String(source[end.lowerBound..<cleanupEnd.lowerBound])
        XCTAssertTrue(cleanup.contains("type_dispatch_gate_ = nil"))
    }

    func testNativeTextGateRejectsLateDuplicateAndWrongTargetDispatch() throws {
        let source = try bridgeSource()
        let start = try XCTUnwrap(source.range(of: "int TatwoClient::DispatchTypeCommand("))
        let end = try XCTUnwrap(source.range(of: "void TatwoClient::TypeText(",
            range: start.upperBound..<source.endIndex))
        let body = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(body.contains("if (gate == nil || !browser) return 0"))
        XCTAssertTrue(body.contains("!NSThread.isMainThread || !accepting || invoked"))
        XCTAssertTrue(body.contains("BrowserInputIsCurrent(owner, generation)"))
        XCTAssertTrue(body.contains("state->browser->IsSame(browser)"))
        let gate = try XCTUnwrap(body.range(of: "const BOOL authorized = gate("))
        let dispatch = try XCTUnwrap(body.range(of: "ExecuteDevToolsMethod("))
        let close = try XCTUnwrap(body.range(of: "accepting = NO"))
        XCTAssertLessThan(gate.lowerBound, dispatch.lowerBound)
        XCTAssertLessThan(dispatch.lowerBound, close.lowerBound)
        XCTAssertTrue(body.contains("return authorized ? message_id : 0"))
    }

    func testNativeTextIsolatedWorldUsesProtocolFrameAndContextBinding() throws {
        // Source contract only. Real CEF reply ordering and isolated-world
        // behavior still require the pinned native runtime, not this test.
        let source = try bridgeSource()
        let start = try XCTUnwrap(source.range(of: "void TatwoClient::TypeText("))
        let end = try XCTUnwrap(source.range(of: "void TatwoClient::FinishTypeText(",
            range: start.upperBound..<source.endIndex))
        let stages = String(source[start.lowerBound..<end.lowerBound])
        let frame = try XCTUnwrap(stages.range(of: #"DispatchTypeCommand(browser, "Page.getFrameTree", params)"#))
        let world = try XCTUnwrap(stages.range(of: #"DispatchTypeCommand(browser, "Page.createIsolatedWorld", params)"#))
        let resolve = try XCTUnwrap(stages.range(of: #"DispatchTypeCommand(browser, "DOM.resolveNode", params)"#))
        let input = try XCTUnwrap(stages.range(of: #"DispatchTypeCommand(browser, "Runtime.callFunctionOn", params)"#))
        XCTAssertLessThan(frame.lowerBound, world.lowerBound)
        XCTAssertLessThan(world.lowerBound, resolve.lowerBound)
        XCTAssertLessThan(resolve.lowerBound, input.lowerBound)
        XCTAssertTrue(stages.contains(#"parsed[@"frameTree"]"#))
        XCTAssertTrue(stages.contains(#"frame[@"parentId"] != nil"#))
        XCTAssertTrue(stages.contains(#"params->SetString("worldName", "TATWOComputerUseInputV1")"#))
        XCTAssertTrue(stages.contains(#"params->SetBool("grantUniveralAccess", false)"#))
        XCTAssertTrue(stages.contains(#"params->SetInt("executionContextId", static_cast<int>(context_id))"#))
        XCTAssertTrue(stages.contains(#"params->SetInt("backendNodeId", type_backend_node_id_)"#))
        XCTAssertTrue(stages.contains(#"![object[@"subtype"] isEqual:@"node"]"#))
        XCTAssertFalse(stages.contains("GetIdentifier("))
        XCTAssertFalse(stages.contains("ExecuteDevToolsMethod("))
        XCTAssertFalse(stages.contains("type_resolving_node_"))
    }

    func testNativeTextContextRejectsMalformedProtocolNumbers() throws {
        let source = try bridgeSource()
        let start = try XCTUnwrap(source.range(of: "if (type_stage_ == TypeStage::creatingWorld)"))
        let end = try XCTUnwrap(source.range(of: "if (type_stage_ == TypeStage::resolvingNode)",
            range: start.upperBound..<source.endIndex))
        let body = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(body.contains("isKindOfClass:NSNumber.class"))
        XCTAssertTrue(body.contains("CFBooleanGetTypeID()"))
        XCTAssertTrue(body.contains("!std::isfinite(context_id)"))
        XCTAssertTrue(body.contains("context_id <= 0"))
        XCTAssertTrue(body.contains("context_id > std::numeric_limits<int>::max()"))
        XCTAssertTrue(body.contains("std::floor(context_id) != context_id"))
        let validation = try XCTUnwrap(body.range(of: "std::floor(context_id) != context_id"))
        let conversion = try XCTUnwrap(body.range(of: "static_cast<int>(context_id)"))
        XCTAssertLessThan(validation.lowerBound, conversion.lowerBound)
    }

    func testNativeTextDispatchRejectsReplacedActionStages() throws {
        let source = try bridgeSource()
        let start = try XCTUnwrap(source.range(of: "int TatwoClient::DispatchTypeCommand("))
        let end = try XCTUnwrap(source.range(of: "void TatwoClient::TypeText(",
            range: start.upperBound..<source.endIndex))
        let body = String(source[start.lowerBound..<end.lowerBound])
        let dispatch = try XCTUnwrap(body.range(of: "ExecuteDevToolsMethod("))
        for check in [
            "state->client.get() != original_client",
            "state->client->type_completion_ == nil",
            "state->client->type_request_serial_ != serial",
            "state->client->type_stage_ != stage",
            "![state->committed_url isEqualToString:expected_url]",
        ] {
            let range = try XCTUnwrap(body.range(of: check))
            XCTAssertLessThan(range.lowerBound, dispatch.lowerBound)
        }
    }

    func testNativeTextCleanupReleasesOnlyOriginalActionObjectGroup() throws {
        let source = try bridgeSource()
        XCTAssertTrue(source.contains(#"[@"tatwo-browser-input:" stringByAppendingString:NSUUID.UUID.UUIDString]"#))
        let start = try XCTUnwrap(source.range(of: "void TatwoClient::FinishTypeText("))
        let end = try XCTUnwrap(source.range(of: "void TatwoClient::CaptureVisibleSnapshot(",
            range: start.upperBound..<source.endIndex))
        let body = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(body.contains("CefRefPtr<CefBrowser> original_browser = type_browser_"))
        XCTAssertTrue(body.contains("NSString *object_group = type_object_group_"))
        XCTAssertTrue(body.contains("state->browser->IsSame(original_browser)"))
        XCTAssertTrue(body.contains(#"params->SetString("objectGroup", ToCefString(object_group))"#))
        let callback = try XCTUnwrap(body.range(of: "if (completion) completion("))
        for reset in [
            "type_browser_ = nullptr", "type_committed_url_ = nil", "type_object_group_ = nil",
            "type_backend_node_id_ = 0", "type_stage_ = TypeStage::idle", "type_dispatch_gate_ = nil",
        ] {
            let range = try XCTUnwrap(body.range(of: reset))
            XCTAssertLessThan(range.lowerBound, callback.lowerBound)
        }
        XCTAssertFalse(body.contains(#"SetString("objectGroup", "tatwo-browser-input")"#))
    }

    func testNativeTextRechecksInputAndFormAfterEachScriptSideEffect() throws {
        // These are script-source guards, not DOM execution or atomicity proof.
        let source = try bridgeSource()
        let start = try XCTUnwrap(source.range(of: "static const char kTatwoTypeIntoNode[]"))
        let end = try XCTUnwrap(source.range(of: ")TATWOJS\";",
            range: start.upperBound..<source.endIndex))
        let script = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(script.contains("location.href !== expectedURL"))
        XCTAssertTrue(script.contains("el.type === inputType"))
        XCTAssertTrue(script.contains("el.form === form"))
        XCTAssertTrue(script.contains("Object.getOwnPropertyDescriptor(HTMLFormElement.prototype, name).get.call(form)"))
        for property in ["action", "method", "target", "enctype"] {
            XCTAssertTrue(script.contains("formValue('\(property)') === form"))
        }
        XCTAssertTrue(script.contains("if (submit && !form) return false"))
        XCTAssertEqual(script.components(separatedBy: "if (!unchanged()) return false").count - 1, 3)
        let focus = try XCTUnwrap(script.range(of: "HTMLElement.prototype.focus.call("))
        let setter = try XCTUnwrap(script.range(of: "setter.call(el, text)"))
        let input = try XCTUnwrap(script.range(of: "new Event('input'"))
        let change = try XCTUnwrap(script.range(of: "new Event('change'"))
        let submit = try XCTUnwrap(script.range(of: "HTMLFormElement.prototype.requestSubmit.call(form)"))
        XCTAssertLessThan(focus.lowerBound, setter.lowerBound)
        XCTAssertLessThan(setter.lowerBound, input.lowerBound)
        XCTAssertLessThan(input.lowerBound, change.lowerBound)
        XCTAssertLessThan(change.lowerBound, submit.lowerBound)
        for range in [focus.upperBound..<setter.lowerBound,
                      input.upperBound..<change.lowerBound,
                      change.upperBound..<submit.lowerBound] {
            XCTAssertNotNil(script.range(of: "if (!unchanged()) return false", range: range))
        }
        XCTAssertFalse(script.contains("el.form.requestSubmit()"))
    }

    func testUnavailableNativeTextGateNeverDispatches() throws {
        let source = try source(relativePath: "Sources/TatwoCEFBridge/TatwoCEFBridgeUnavailable.m")
        let start = try XCTUnwrap(source.range(of:
            "- (void)typeText:(NSString *)text elementID:(NSString *)elementID\n" +
            "    navigationGeneration:(uint64_t)generation submit:(BOOL)submit\n" +
            "    dispatchGate:(TatwoCEFBrowserInputDispatchGate)dispatchGate"))
        let end = try XCTUnwrap(source.range(of: "- (void)loadURLString:",
            range: start.upperBound..<source.endIndex))
        let body = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(body.contains(#"completion(NO, @"browser_unavailable")"#))
        XCTAssertFalse(body.contains("dispatchGate("))
    }

    func testRealCEFPolicyRejectsSpecialLoopbackSpellings() throws {
        guard TatwoCEFRuntime.compiled else {
            throw XCTSkip("real CEF bridge was not compiled")
        }

        for rawURL in [
            "http://2130706433/",
            "http://127.1/",
            "http://0x7f000001/",
            "http://[::ffff:127.0.0.1]/",
            "http://[::ffff:" + [192, 168, 1, 1].map(String.init).joined(separator: ".") + "]/",
        ] {
            XCTAssertFalse(
                TatwoCEFURLPolicyAllowsURLString(rawURL),
                rawURL)
        }
        XCTAssertTrue(
            TatwoCEFURLPolicyAllowsURLString("https://example.com/"))
    }

    func testRealCEFResolvedPolicyAllowsKnownPublicDestinations() throws {
        guard TatwoCEFRuntime.compiled else {
            throw XCTSkip("real CEF bridge was not compiled")
        }

        for rawURL in [
            "https://example.com/",
            "https://www.google.com/",
        ] {
            XCTAssertTrue(
                TatwoCEFResolvedURLPolicyAllowsURLString(rawURL),
                rawURL)
        }
        XCTAssertFalse(
            TatwoCEFResolvedURLPolicyAllowsURLString(
                "http://127.0.0.1/"))
    }

    func testCEFMacApplicationHostClassIsLinkedAndImplementsProtocol()
        throws
    {
        guard TatwoCEFRuntime.compiled else {
            throw XCTSkip("real CEF bridge was not compiled")
        }

        let applicationClass = try XCTUnwrap(
            NSClassFromString("TatwoCEFApplication"))
        XCTAssertTrue(
            class_getInstanceMethod(
                applicationClass,
                #selector(TatwoCEFApplication.isHandlingSendEvent)) != nil)
        XCTAssertTrue(
            class_getInstanceMethod(
                applicationClass,
                #selector(
                    TatwoCEFApplication.setHandlingSendEvent(_:))) != nil)
        let cefProtocol = try XCTUnwrap(
            NSProtocolFromString("CefAppProtocol"))
        XCTAssertTrue(
            class_conformsToProtocol(applicationClass, cefProtocol))
    }

    func testCustomMainSelectsCEFApplicationHostSingleton() throws {
        let applicationHostType: NSApplication.Type =
            TatwoCEFApplication.self
        XCTAssertEqual(
            ObjectIdentifier(applicationHostType),
            ObjectIdentifier(TatwoCEFApplication.self))

        let source = try source(
            relativePath: "Sources/TatwoUltraworkMac/AppShell.swift")
        XCTAssertTrue(source.contains("import TatwoCEFBridge"))

        let mainStart = try XCTUnwrap(
            source.range(of: "enum TatwoUltraworkMacApp {"))
        let mainEnd = try XCTUnwrap(
            source.range(
                of: "enum TatwoSingleInstanceGuard {",
                range: mainStart.upperBound..<source.endIndex))
        let mainBody = String(
            source[mainStart.lowerBound..<mainEnd.lowerBound])
        XCTAssertTrue(mainBody.contains(
            "let application: NSApplication = TatwoCEFApplication.shared"))
        XCTAssertFalse(mainBody.contains("NSApplication.shared"))
    }

    func testRealCEFHostArgvDenyListCoversUnsafeSwitches() throws {
        guard TatwoCEFRuntime.compiled else {
            throw XCTSkip("real CEF bridge was not compiled")
        }

        for switchName in [
            "remote-debugging-port",
            "--remote-debugging-address",
            "remote-debugging-pipe",
            "remote-allow-origins",
            "user-data-dir",
            "no-sandbox",
            "disable-web-security",
            "allow-running-insecure-content",
            "allow-insecure-localhost",
            "ignore-certificate-errors",
            "disable-site-isolation-trials",
            "disable-features",
        ] {
            XCTAssertTrue(
                TatwoCEFHostSwitchIsDenied(switchName),
                switchName)
        }
        XCTAssertFalse(TatwoCEFHostSwitchIsDenied("no-first-run"))
    }

    func testWebMCPUsesRendererBindingIPCAndNavigationBoundRegistry()
        throws
    {
        let bridge = try bridgeSource()
        for required in [
            "public CefRenderProcessHandler",
            "GetRenderProcessHandler() override",
            "\"modelContext\"",
            "\"registerTool\"",
            "\"unregisterTool\"",
            "tatwo.webmcp.register",
            "tatwo.webmcp.invoke",
            "OnProcessMessageReceived(",
            "InvalidateWebMCPTools(view, state)",
            "@\"navigationGeneration\"",
            "@\"origin\"",
            "CancelPendingWebMCPInvocations(",
        ] {
            XCTAssertTrue(bridge.contains(required), required)
        }
        XCTAssertTrue(bridge.contains(
            "g_webmcp_renderer_hook_active.load("))
        XCTAssertFalse(bridge.contains(
            "supportsChromiumWebMCP = false"))

        let helper = try source(
            relativePath: "Sources/TatwoCEFHelper/main.swift")
        XCTAssertTrue(helper.contains("TatwoCEFExecuteSubprocess()"))
    }

    func testWebMCPOriginParsingFailsClosedWithoutFoundationExceptions()
        throws
    {
        let source = try bridgeSource()
        XCTAssertTrue(source.contains(
            "NSURLComponents *SafeURLComponents("))
        XCTAssertTrue(source.contains(
            "encodingInvalidCharacters:YES"))
        XCTAssertTrue(source.contains("@catch (NSException *exception)"))
        XCTAssertFalse(source.contains(
            "[NSURLComponents componentsWithString:url_string]"))

        let publishStart = try XCTUnwrap(
            source.range(of: "void PublishWebMCPToolsSnapshot("))
        let invalidateStart = try XCTUnwrap(
            source.range(
                of: "void InvalidateWebMCPTools(",
                range: publishStart.upperBound..<source.endIndex))
        let publishBody = String(
            source[publishStart.lowerBound..<invalidateStart.lowerBound])
        let unresolved = try XCTUnwrap(
            publishBody.range(
                of: "event=webmcp_origin_unresolved"))
        let snapshot = try XCTUnwrap(
            publishBody.range(
                of: "@\"schema\": @\"TatwoCEFWebMCPToolsSnapshotV1\""))
        XCTAssertLessThan(unresolved.lowerBound, snapshot.lowerBound)
        XCTAssertTrue(publishBody.contains(
            "if (origin.length == 0)"))
        XCTAssertTrue(publishBody.contains(
            "AppendCEFEmbeddingTelemetryLine("))
    }

    func testCEFRequestPolicyAppliesGPCReferrerCredentialCookieAndRedirectRules()
        throws
    {
        let source = try bridgeSource()
        let handlerStart = try XCTUnwrap(
            source.range(of: "class TatwoResourceRequestHandler final"))
        let clientStart = try XCTUnwrap(
            source.range(
                of: "class TatwoClient final",
                range: handlerStart.upperBound..<source.endIndex))
        let handler = String(
            source[handlerStart.lowerBound..<clientStart.lowerBound])

        XCTAssertTrue(handler.contains(
            "request->SetHeaderByName(\"Sec-GPC\", \"1\", true)"))
        XCTAssertTrue(handler.contains("request->SetReferrer("))
        XCTAssertTrue(handler.contains("REFERRER_POLICY_ORIGIN"))
        XCTAssertTrue(handler.contains("URLHasCredentials(request_url)"))
        XCTAssertFalse(handler.contains(
            "SetHeaderByName(\"Origin\""))
        XCTAssertFalse(handler.contains(
            "SetHeaderByName(\"origin\""))

        XCTAssertTrue(source.contains(
            "class TatwoThirdPartyCookieAccessFilter final"))
        XCTAssertTrue(source.contains("bool CanSendCookie("))
        XCTAssertTrue(source.contains("bool CanSaveCookie("))
        XCTAssertTrue(source.contains(
            "bool blocks_third_party_cookies = true"))
        XCTAssertTrue(source.contains("return IsSameSite("))

        XCTAssertTrue(handler.contains("OnResourceRedirect("))
        XCTAssertTrue(handler.contains("OnProtocolExecution("))
        XCTAssertTrue(handler.contains("allow_os_execution = false"))
        XCTAssertTrue(handler.contains("request->GetResourceType()"))
        XCTAssertTrue(handler.contains("IsMainFrameRequest(request)"))
        XCTAssertTrue(handler.contains("RV_CONTINUE_ASYNC"))
        XCTAssertTrue(handler.contains("dispatch_get_global_queue("))

        let callbackStart = try XCTUnwrap(
            handler.range(of: "cef_return_value_t OnBeforeResourceLoad("))
        let callbackEnd = try XCTUnwrap(
            handler.range(
                of: "void OnResourceRedirect(",
                range: callbackStart.upperBound..<handler.endIndex))
        let callback = String(
            handler[callbackStart.lowerBound..<callbackEnd.lowerBound])
        let dispatch = try XCTUnwrap(
            callback.range(of: "dispatch_async("))
        let dns = try XCTUnwrap(
            callback.range(of: "ResolvePublicAddressResult("))
        XCTAssertLessThan(dispatch.lowerBound, dns.lowerBound)
        XCTAssertFalse(callback[..<dispatch.lowerBound].contains(
            "NSJSONSerialization"))
        XCTAssertFalse(callback[..<dispatch.lowerBound].contains(
            "ReadBoundedRegularFile"))
    }

    func testCEFTLSAuthProtocolAndAutofillPoliciesFailClosed() throws {
        let source = try bridgeSource()
        XCTAssertTrue(source.contains("bool GetAuthCredentials("))
        XCTAssertTrue(source.contains("return false;"))
        XCTAssertTrue(source.contains("bool OnCertificateError("))
        XCTAssertTrue(source.contains("kCertificateBlockedError"))
        XCTAssertTrue(source.contains(
            "callback->Select(nullptr)"))
        XCTAssertTrue(source.contains(
            "allow_os_execution = false"))

        for preference in [
            "credentials_enable_service",
            "profile.password_manager_enabled",
            "autofill.credit_card_enabled",
            "autofill.profile_enabled",
            "ssl.error_override_allowed",
        ] {
            XCTAssertTrue(source.contains(preference), preference)
        }
        XCTAssertTrue(source.contains("CanSetPreference("))
        XCTAssertTrue(source.contains("SetPreference("))
        XCTAssertTrue(source.contains(
            "ApplyPrivacyStrictRequestContextPreferences("))
        XCTAssertTrue(source.contains(
            "event=preference_unavailable"))
        XCTAssertTrue(source.contains(
            "event=preference_failed"))
        XCTAssertTrue(source.contains(
            #"{"ssl.error_override_allowed", true}"#))
        XCTAssertTrue(source.contains(
            "requiredForPrivacyStrict=%d"))
        XCTAssertTrue(source.contains(
            "sslErrorOverride=0"))

        let mutabilityCheck = try XCTUnwrap(
            source.range(
                of: "request_context->CanSetPreference("))
        let unavailableReceipt = try XCTUnwrap(
            source.range(
                of: "event=preference_unavailable",
                range: mutabilityCheck.upperBound..<source.endIndex))
        let requiredFailure = try XCTUnwrap(
            source.range(
                of: "if (preference.required_for_privacy_strict)",
                range: unavailableReceipt.upperBound..<source.endIndex))
        let valueCreation = try XCTUnwrap(
            source.range(
                of: "CefRefPtr<CefValue> value = CefValue::Create()",
                range: requiredFailure.upperBound..<source.endIndex))
        let unavailableBranch = String(
            source[mutabilityCheck.lowerBound..<valueCreation.lowerBound])
        XCTAssertLessThan(
            mutabilityCheck.lowerBound,
            unavailableReceipt.lowerBound)
        XCTAssertLessThan(
            unavailableReceipt.lowerBound,
            requiredFailure.lowerBound)
        XCTAssertLessThan(
            requiredFailure.lowerBound,
            valueCreation.lowerBound)
        XCTAssertTrue(unavailableBranch.contains("return false;"))
        XCTAssertFalse(unavailableBranch.contains(
            "event=preference_failed"))

        let contextHandlerStart = try XCTUnwrap(
            source.range(
                of: "class TatwoPrivacyStrictRequestContextHandler final"))
        let requestHandlerStart = try XCTUnwrap(
            source.range(
                of: "class TatwoResourceRequestHandler final",
                range:
                    contextHandlerStart.upperBound..<source.endIndex))
        let contextHandler = String(
            source[
                contextHandlerStart.lowerBound
                    ..< requestHandlerStart.lowerBound
            ])
        XCTAssertTrue(contextHandler.contains(
            "public CefRequestContextHandler"))
        XCTAssertTrue(contextHandler.contains(
            "void OnRequestContextInitialized("))
        XCTAssertTrue(contextHandler.contains(
            "ApplyPrivacyStrictRequestContextPreferences("))

        let originClearStart = try XCTUnwrap(
            source.range(
                of: "class TatwoOriginDataClearOperation final"))
        let originClearEnd = try XCTUnwrap(
            source.range(
                of: "std::vector<CefRefPtr<TatwoOriginDataClearOperation>>",
                range: originClearStart.upperBound..<source.endIndex))
        let originClear = String(
            source[
                originClearStart.lowerBound..<originClearEnd.lowerBound
            ])
        let normalizedOriginClear = originClear.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression)
        XCTAssertTrue(normalizedOriginClear.contains(
            "request_context_handler_ = "
                + "new TatwoPrivacyStrictRequestContextHandler("))
        XCTAssertTrue(normalizedOriginClear.contains(
            "CefRequestContext::CreateContext( settings, "
                + "request_context_handler_)"))
        XCTAssertFalse(originClear.contains(
            "if (!ApplyPrivacyStrictRequestContextPreferences("))

        let browserInitStart = try XCTUnwrap(
            source.range(
                of: "- (nullable instancetype)initWithFrame:"))
        let browserInitEnd = try XCTUnwrap(
            source.range(
                of: "- (void)dealloc",
                range: browserInitStart.upperBound..<source.endIndex))
        let browserInit = String(
            source[
                browserInitStart.lowerBound..<browserInitEnd.lowerBound
            ])
        let normalizedBrowserInit = browserInit.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression)
        XCTAssertTrue(normalizedBrowserInit.contains(
            "state->request_context_handler = "
                + "new TatwoPrivacyStrictRequestContextHandler("))
        XCTAssertTrue(normalizedBrowserInit.contains(
            "CefRequestContext::CreateContext( context_settings, "
                + "state->request_context_handler)"))
        XCTAssertTrue(browserInit.contains(
            "TatwoCEFBrowserPhaseBlockedBySecurity"))
        XCTAssertTrue(browserInit.contains(
            "TatwoCEFBrowserErrorKindSecurity"))
        XCTAssertFalse(browserInit.contains(
            "if (!ApplyPrivacyStrictRequestContextPreferences("))

        let startBrowserStart = try XCTUnwrap(
            source.range(of: "- (void)startBrowserIfReady {"))
        let startBrowserEnd = try XCTUnwrap(
            source.range(
                of: "- (void)layout",
                range: startBrowserStart.upperBound..<source.endIndex))
        let startBrowser = String(
            source[
                startBrowserStart.lowerBound..<startBrowserEnd.lowerBound
            ])
        XCTAssertTrue(startBrowser.contains(
            "!state->request_context_security_ready"))
    }

    func testCEFCertificateErrorsAreUnconditionallyDeniedAndReceipted()
        throws
    {
        let source = try bridgeSource()
        let start = try XCTUnwrap(
            source.range(of: "bool OnCertificateError("))
        let end = try XCTUnwrap(
            source.range(
                of: "bool OnSelectClientCertificate(",
                range: start.upperBound..<source.endIndex))
        let body = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(body.contains(
            "CanonicalHost(FromCefString(request_url))"))
        XCTAssertTrue(body.contains(
            "phase=security_capability event=certificate_error_denied"))
        XCTAssertTrue(body.contains("code=%d host=%@"))
        XCTAssertTrue(body.contains("kCertificateBlockedError"))
        XCTAssertTrue(body.contains("return false;"))
        XCTAssertFalse(body.contains("callback->Continue"))
        XCTAssertFalse(body.contains("return true;"))
        XCTAssertFalse(body.contains("IsMain()"))
    }

    func testCEFShutdownReleasesBridgeReferencesBeforeCefShutdown()
        throws
    {
        let source = try bridgeSource()
        let shutdownStart = try XCTUnwrap(
            source.range(of: "+ (void)shutdown {"))
        let shutdownEnd = try XCTUnwrap(
            source.range(
                of: "@end",
                range: shutdownStart.upperBound..<source.endIndex))
        let shutdown = String(
            source[shutdownStart.lowerBound..<shutdownEnd.lowerBound])

        let drain = try XCTUnwrap(
            shutdown.range(of: "DrainCEFReferencesForShutdown()"))
        let releaseApplication = try XCTUnwrap(
            shutdown.range(of: "g_application = nullptr"))
        let cefShutdown = try XCTUnwrap(
            shutdown.range(of: "CefShutdown()"))
        XCTAssertLessThan(drain.lowerBound, releaseApplication.lowerBound)
        XCTAssertLessThan(
            releaseApplication.lowerBound,
            cefShutdown.lowerBound)
        XCTAssertTrue(shutdown.contains(
            "event=cef_shutdown_skipped"))
        XCTAssertTrue(shutdown.contains(
            "reason=live_references"))

        let closeStart = try XCTUnwrap(
            source.range(of: "void CompleteBrowserClose("))
        let closeEnd = try XCTUnwrap(
            source.range(
                of: "void TatwoClient::OnAfterCreated(",
                range: closeStart.upperBound..<source.endIndex))
        let close = String(
            source[closeStart.lowerBound..<closeEnd.lowerBound])
        let cancelOperations = try XCTUnwrap(
            close.range(of: "CancelPendingBrowserOperations()"))
        let releaseBrowser = try XCTUnwrap(
            close.range(of: "state->browser = nullptr"))
        let releaseContext = try XCTUnwrap(
            close.range(of: "state->request_context = nullptr"))
        let releaseClient = try XCTUnwrap(
            close.range(of: "state->client = nullptr"))
        XCTAssertLessThan(cancelOperations.lowerBound, releaseBrowser.lowerBound)
        XCTAssertLessThan(releaseBrowser.lowerBound, releaseContext.lowerBound)
        XCTAssertLessThan(releaseContext.lowerBound, releaseClient.lowerBound)
        XCTAssertTrue(close.contains(
            "state->request_context_handler->Cancel()"))
        XCTAssertTrue(close.contains(
            "[g_live_browser_views removeObject:view]"))
        let cancelStart = try XCTUnwrap(
            source.range(of: "void TatwoClient::CancelPendingBrowserOperations()"))
        let cancelEnd = try XCTUnwrap(
            source.range(
                of: "bool TatwoClient::OnProcessMessageReceived(",
                range: cancelStart.upperBound..<source.endIndex))
        let cancel = String(source[cancelStart.lowerBound..<cancelEnd.lowerBound])
        XCTAssertTrue(cancel.contains(
            #"FinishTypeText(NO, @"browser_action_result_unavailable")"#))
        XCTAssertTrue(cancel.contains(
            #"FinishVisibleSnapshot(nil, @"snapshot_unavailable")"#))

        let snapshotStart = try XCTUnwrap(
            source.range(of: "void TatwoClient::CaptureVisibleSnapshot("))
        let snapshotEnd = try XCTUnwrap(
            source.range(
                of: "void TatwoClient::OnDevToolsMethodResult(",
                range: snapshotStart.upperBound..<source.endIndex))
        let snapshot = String(
            source[snapshotStart.lowerBound..<snapshotEnd.lowerBound])
        XCTAssertTrue(snapshot.contains(
            "__weak TatwoCEFBrowserView *weak_owner"))
        XCTAssertFalse(snapshot.contains(
            "CefRefPtr<TatwoClient> self = this"))

        let drainStart = try XCTUnwrap(
            source.range(
                of: "bool CEFBridgeReferencesReleasedForShutdown()"))
        let namespaceEnd = try XCTUnwrap(
            source.range(
                of: "}  // namespace",
                range: drainStart.upperBound..<source.endIndex))
        let drainBody = String(
            source[drainStart.lowerBound..<namespaceEnd.lowerBound])
        XCTAssertTrue(drainBody.contains(
            "PrepareCEFReferencesForShutdown()"))
        XCTAssertTrue(drainBody.contains("CefDoMessageLoopWork()"))
        XCTAssertTrue(drainBody.contains(
            "CEFBridgeReferencesReleasedForShutdown()"))
        XCTAssertTrue(drainBody.contains(
            "CancelPendingResourceDecisionsForShutdown()"))
        XCTAssertTrue(drainBody.contains(
            "PendingResourceDecisionCount() == 0"))

        let resourceStart = try XCTUnwrap(
            source.range(of: "cef_return_value_t OnBeforeResourceLoad("))
        let resourceEnd = try XCTUnwrap(
            source.range(
                of: "void OnResourceRedirect(",
                range: resourceStart.upperBound..<source.endIndex))
        let resource = String(
            source[resourceStart.lowerBound..<resourceEnd.lowerBound])
        XCTAssertTrue(resource.contains(
            "RegisterPendingResourceDecision(callback, &decision_id)"))
        XCTAssertTrue(resource.contains(
            "CompletePendingResourceDecision(decision_id, allow)"))
        XCTAssertFalse(resource.contains(
            "CefRefPtr<CefCallback> continuation = callback"))

        let browserInitStart = try XCTUnwrap(
            source.range(of: "- (nullable instancetype)initWithFrame:"))
        let browserInitEnd = try XCTUnwrap(
            source.range(
                of: "- (void)dealloc",
                range: browserInitStart.upperBound..<source.endIndex))
        let browserInit = String(
            source[browserInitStart.lowerBound..<browserInitEnd.lowerBound])
        XCTAssertTrue(browserInit.contains(
            "g_shutdown_requested.load()"))

        let startBrowserStart = try XCTUnwrap(
            source.range(of: "- (void)startBrowserIfReady {"))
        let startBrowserEnd = try XCTUnwrap(
            source.range(
                of: "- (void)layout",
                range: startBrowserStart.upperBound..<source.endIndex))
        let startBrowser = String(
            source[startBrowserStart.lowerBound..<startBrowserEnd.lowerBound])
        XCTAssertTrue(startBrowser.contains(
            "g_shutdown_requested.load()"))
    }

    func testCEFWebRTCPolicyIsVersionedReceiptedAndPrivacyStrict() throws {
        let source = try bridgeSource()
        XCTAssertTrue(source.contains(
            "kBrowserNetworkSecurityPolicyVersion = 1"))
        XCTAssertTrue(source.contains(
            "\"webrtc-ip-handling-policy\""))
        XCTAssertTrue(source.contains(
            "\"disable_non_proxied_udp\""))
        XCTAssertTrue(source.contains(
            "g_webrtc_ip_policy_configured.store("))
        XCTAssertTrue(source.contains(
            "event=webrtc_ip_policy"))
        XCTAssertTrue(source.contains("privacyStrict=1"))
        XCTAssertTrue(source.contains(
            "if (!g_webrtc_ip_policy_configured.load("))
        XCTAssertTrue(source.contains(
            "*error = MakeError(16, kPrivacyStrictStartupError)"))
    }

    func testCEFLocalDenyListLoadsBeforeCallbacksAndUsesMemoryMatcher()
        throws
    {
        let source = try bridgeSource()
        for token in [
            "TatwoBrowserHostDenyListV1",
            "bundledDenyListPath",
            "admin-deny-list.json",
            "user-deny-list.json",
            "O_RDONLY | O_CLOEXEC | O_NOFOLLOW",
            "exact_hosts.contains(host)",
            "suffix_hosts.contains(suffix)",
            "LoadHostDenyListSnapshot(",
            "bundledSuffixCount=%zu",
            "ResourceBlockMessage",
        ] {
            XCTAssertTrue(source.contains(token), token)
        }
        let handlerStart = try XCTUnwrap(
            source.range(of: "class TatwoResourceRequestHandler final"))
        let clientStart = try XCTUnwrap(
            source.range(
                of: "class TatwoClient final",
                range: handlerStart.upperBound..<source.endIndex))
        let handler = String(
            source[handlerStart.lowerBound..<clientStart.lowerBound])
        XCTAssertTrue(handler.contains("IsDeniedByLocalHostList("))
        XCTAssertFalse(handler.contains("NSJSONSerialization"))
        XCTAssertFalse(handler.contains("ReadBoundedRegularFile"))
        XCTAssertFalse(handler.contains("Data(contentsOf:"))
    }

    func testCEFHostBlocklistCancelsSubresourcesAndCountsBlocks()
        throws
    {
        let source = try bridgeSource()
        let handlerStart = try XCTUnwrap(
            source.range(of: "class TatwoResourceRequestHandler final"))
        let clientStart = try XCTUnwrap(
            source.range(
                of: "class TatwoClient final",
                range: handlerStart.upperBound..<source.endIndex))
        let handler = String(
            source[handlerStart.lowerBound..<clientStart.lowerBound])
        let callbackStart = try XCTUnwrap(
            handler.range(of: "cef_return_value_t OnBeforeResourceLoad("))
        let callback = String(handler[callbackStart.lowerBound...])

        XCTAssertTrue(callback.contains(
            "const bool local_deny ="))
        XCTAssertTrue(callback.contains(
            "RecordHostBlocklistRequest("))
        XCTAssertTrue(callback.contains(
            "request->GetResourceType()"))
        XCTAssertTrue(callback.contains("return RV_CANCEL;"))
        XCTAssertFalse(callback.contains(
            "if (is_main_frame) {\n      return RV_CANCEL;"))

        let telemetryStart = try XCTUnwrap(
            source.range(of: "void RecordHostBlocklistRequest("))
        let lifecycleStart = try XCTUnwrap(
            source.range(
                of: "void LogBrowserLifecycle(",
                range: telemetryStart.upperBound..<source.endIndex))
        let telemetry = String(
            source[telemetryStart.lowerBound..<lifecycleStart.lowerBound])
        for token in [
            "phase=adblock event=request_blocked",
            "totalCount=%llu",
            "mainFrameCount=%llu",
            "subresourceCount=%llu",
            "resourceType=%d",
        ] {
            XCTAssertTrue(telemetry.contains(token), token)
        }
        XCTAssertFalse(telemetry.contains("request_url"))
        XCTAssertFalse(telemetry.contains("url_string"))
        XCTAssertFalse(telemetry.contains("host="))
    }

    func testCEFCommittedNavigationGenerationAndDocumentEpochInvalidate()
        throws
    {
        let source = try bridgeSource()
        XCTAssertTrue(source.contains(
            "uint64_t security_navigation_generation = 0"))
        XCTAssertTrue(source.contains(
            "uint64_t document_epoch = 0"))
        XCTAssertTrue(source.contains(
            "state->security_navigation_generation += 1"))
        XCTAssertTrue(source.contains("state->document_epoch += 1"))
        XCTAssertTrue(source.contains(
            "state->document_epoch_valid = true"))
        XCTAssertTrue(source.contains(
            "InvalidateSecurityDocumentEpoch("))
        XCTAssertTrue(source.contains(
            "owner_, @\"renderer_terminated\""))
        XCTAssertTrue(source.contains(
            "event=invalidated reason=close"))
    }

    func testUnavailableBridgeCannotMasqueradeAsCEFPolicyCoverage() throws {
        guard !TatwoCEFRuntime.compiled else {
            throw XCTSkip("real CEF bridge is present")
        }

        XCTAssertFalse(
            TatwoCEFURLPolicyAllowsURLString("https://example.com/"))
        XCTAssertFalse(
            TatwoCEFHostSwitchIsDenied("remote-debugging-port"))
    }

    func testRealCEFOriginDataClearCapabilitySeparatesSiteDataFromHTTPCache()
        throws
    {
        guard TatwoCEFRuntime.compiled else {
            throw XCTSkip("real CEF bridge is not present")
        }

        XCTAssertTrue(
            TatwoCEFRuntime.supportsOriginScopedSiteDataClearing)
        XCTAssertFalse(
            TatwoCEFRuntime
                .supportsOriginScopedHTTPResponseCacheClearing,
            "CEF 151 cannot guarantee origin-scoped HTTP response cache clearing")
    }

    func testOriginClearBridgeHasNoProfileWideFallback() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(
                "Sources/TatwoCEFBridge/TatwoCEFBridge.mm")
        let source = try String(
            contentsOf: sourceURL,
            encoding: .utf8)
        XCTAssertTrue(source.contains("VisitUrlCookies("))
        XCTAssertTrue(source.contains("deleteCookie = true"))
        XCTAssertTrue(
            source.contains("\"Storage.clearDataForOrigin\""))
        for storageType in [
            "local_storage",
            "indexeddb",
            "service_workers",
            "cache_storage",
        ] {
            XCTAssertTrue(source.contains(storageType), storageType)
        }
        XCTAssertFalse(source.contains("->ClearHttpCache("))
        XCTAssertFalse(source.contains("->DeleteCookies("))
        XCTAssertTrue(
            source.contains(
                "supportsOriginScopedHTTPResponseCacheClearing"))
    }

    func testChromiumStartupFailureBecomesVisibleSurfaceFallback() {
        let timeout = EmbeddedBrowserVisibleError.runtimeMessage(
            "Chromium 啟動逾時，個人資料或子程序無法初始化")

        XCTAssertEqual(
            EmbeddedBrowserRuntimeFailurePresentation
                .startupFailureMessage(
                    engine: .chromiumCEF,
                    currentURLString: "",
                    visibleError: timeout),
            timeout.message)
        XCTAssertEqual(
            EmbeddedBrowserRuntimeFailurePresentation
                .startupFailureMessage(
                    engine: .chromiumCEF,
                    currentURLString: "https://www.google.com/",
                    visibleError: timeout),
            timeout.message,
            "stale URL state from a previous profile must not suppress a startup failure")
        XCTAssertNil(
            EmbeddedBrowserRuntimeFailurePresentation
                .startupFailureMessage(
                    engine: .chromiumCEF,
                    currentURLString: "https://www.google.com/",
                    phase: .finished,
                    visibleError: timeout),
            "only an actual startup-failed phase may replace loaded content")
        XCTAssertNil(
            EmbeddedBrowserRuntimeFailurePresentation
                .startupFailureMessage(
                    engine: .webKitLegacy,
                    currentURLString: "",
                    visibleError: timeout),
            "the CEF startup fallback must not relabel WebKit failures")
    }

    func testCEFActivePageClearsOnlyWhenStateProvesNoPageIsActive() {
        func state(
            phase: EmbeddedBrowserLoadPhase,
            urlString: String? = nil
        ) -> EmbeddedBrowserNavigationState {
            EmbeddedBrowserNavigationState(
                urlString: urlString,
                canGoBack: true,
                canGoForward: true,
                visibleError: nil,
                phase: phase)
        }

        for phase in [
            EmbeddedBrowserLoadPhase.blank,
            .startupFailed,
            .closed,
        ] {
            XCTAssertTrue(
                EmbeddedBrowserActivePageRetentionPolicy
                    .shouldClearActivePage(for: state(phase: phase)),
                phase.rawValue)
        }
        for phase in [
            EmbeddedBrowserLoadPhase.creating,
            .loading,
            .committed,
            .finished,
            .blockedBySecurity,
            .navigationFailed,
            .rendererFailed,
        ] {
            XCTAssertFalse(
                EmbeddedBrowserActivePageRetentionPolicy
                    .shouldClearActivePage(for: state(phase: phase)),
                phase.rawValue)
        }
        XCTAssertFalse(
            EmbeddedBrowserActivePageRetentionPolicy
                .shouldClearActivePage(
                    for: state(
                        phase: .startupFailed,
                        urlString: "https://www.google.com/")),
            "a callback that still identifies an active page must not clear its origin")
    }

    func testCEFChildWindowCreationWaitsForAttachedNonzeroViewExactlyOnce()
        throws
    {
        let source = try bridgeSource()
        let start = try XCTUnwrap(
            source.range(of: "- (void)startBrowserIfReady {"))
        let creation = try XCTUnwrap(
            source.range(
                of: "CefBrowserHost::CreateBrowser(",
                range: start.lowerBound..<source.endIndex))
        let attachedGuard = try XCTUnwrap(
            source.range(
                of: "self.window == nil",
                range: start.lowerBound..<creation.lowerBound))
        let widthGuard = try XCTUnwrap(
            source.range(
                of: "self.bounds.size.width < 1",
                range: start.lowerBound..<creation.lowerBound))
        let heightGuard = try XCTUnwrap(
            source.range(
                of: "self.bounds.size.height < 1",
                range: start.lowerBound..<creation.lowerBound))
        let exactOnceGuard = try XCTUnwrap(
            source.range(
                of: "state->creation_attempted",
                range: start.lowerBound..<creation.lowerBound))

        XCTAssertLessThan(attachedGuard.lowerBound, creation.lowerBound)
        XCTAssertLessThan(widthGuard.lowerBound, creation.lowerBound)
        XCTAssertLessThan(heightGuard.lowerBound, creation.lowerBound)
        XCTAssertLessThan(exactOnceGuard.lowerBound, creation.lowerBound)
        XCTAssertTrue(source.contains("- (void)viewDidMoveToWindow"))
        XCTAssertTrue(source.contains("- (void)viewDidMoveToSuperview"))
        XCTAssertTrue(source.contains("[self startBrowserIfReady];"))
        let preCreationBody = String(
            source[start.lowerBound..<creation.lowerBound])
        XCTAssertTrue(preCreationBody.contains(
            "[self setWantsLayer:YES]"))
        XCTAssertTrue(preCreationBody.contains(
            "LogBrowserEmbeddingSnapshot(self, nullptr, @\"before_create\""))
        XCTAssertTrue(source.contains(
            "LogBrowserLifecycle(@\"create_accepted\")"))
    }

    func testCEFWindowedBrowserLayerBacksDirectParentBeforeChildCreation()
        throws
    {
        let source = try bridgeSource()
        let start = try XCTUnwrap(
            source.range(of: "- (void)startBrowserIfReady {"))
        let creation = try XCTUnwrap(
            source.range(
                of: "CefBrowserHost::CreateBrowser(",
                range: start.lowerBound..<source.endIndex))
        let body = String(source[start.lowerBound..<creation.lowerBound])
        let rootContentView = try XCTUnwrap(
            body.range(of: "self.window.contentView"))
        let rootLayerBacking = try XCTUnwrap(
            body.range(of: "[content_view setWantsLayer:YES]"))
        let directParentLayerBacking = try XCTUnwrap(
            body.range(of: "[self setWantsLayer:YES]"))
        let childParent = try XCTUnwrap(
            body.range(of: "window_info.SetAsChild("))

        XCTAssertLessThan(
            rootContentView.lowerBound,
            rootLayerBacking.lowerBound)
        XCTAssertLessThan(
            rootLayerBacking.lowerBound,
            directParentLayerBacking.lowerBound)
        XCTAssertLessThan(
            directParentLayerBacking.lowerBound,
            childParent.lowerBound)
        XCTAssertTrue(source.contains(
            "settings.windowless_rendering_enabled = false"))
    }

    func testCEFReadyCallbackSynchronizesChildAndFlushesLatestPendingURL()
        throws
    {
        let source = try bridgeSource()
        let callback = try XCTUnwrap(
            source.range(of: "void TatwoClient::OnAfterCreated"))
        let callbackEnd = try XCTUnwrap(
            source.range(
                of: "void TatwoClient::OnBeforeClose",
                range: callback.upperBound..<source.endIndex))
        let body = String(
            source[callback.lowerBound..<callbackEnd.lowerBound])

        XCTAssertTrue(body.contains(
            "SynchronizeBrowserGeometry(owner, browser)"))
        XCTAssertTrue(body.contains("[owner setNeedsLayout:YES]"))
        XCTAssertTrue(body.contains(
            "NSString *pending_url = [state->pending_url copy]"))
        XCTAssertTrue(body.contains("state->pending_url = nil"))
        XCTAssertTrue(body.contains(
            "browser->GetMainFrame()->LoadURL(ToCefString(pending_url))"))
        XCTAssertTrue(body.contains(
            "LogBrowserLifecycle(@\"on_after_created\")"))
        XCTAssertTrue(body.contains(
            "LogBrowserEmbeddingSnapshot(owner, browser, @\"on_after_created\""))
        XCTAssertTrue(body.contains(
            "@\"on_after_created_500ms\""))

        let loadMethod = try XCTUnwrap(
            source.range(of: "- (void)loadURLString:"))
        let loadEnd = try XCTUnwrap(
            source.range(
                of: "- (void)goBack",
                range: loadMethod.upperBound..<source.endIndex))
        let loadBody = String(
            source[loadMethod.lowerBound..<loadEnd.lowerBound])
        XCTAssertTrue(loadBody.contains(
            "state->pending_url = [urlString copy]"))
        XCTAssertTrue(loadBody.contains(
            "!state->creation_attempted || state->creation_pending"))
    }

    func testCEFFirstPendingNavigationRequestsNativeDisplayBeforeLoadURL()
        throws
    {
        let source = try bridgeSource()
        let callback = try XCTUnwrap(
            source.range(of: "void TatwoClient::OnAfterCreated"))
        let callbackEnd = try XCTUnwrap(
            source.range(
                of: "void TatwoClient::OnBeforeClose",
                range: callback.upperBound..<source.endIndex))
        let callbackBody = String(
            source[callback.lowerBound..<callbackEnd.lowerBound])
        let geometry = try XCTUnwrap(
            callbackBody.range(
                of: "SynchronizeBrowserGeometry(owner, browser)"))
        let displayRequest = try XCTUnwrap(
            callbackBody.range(
                of: "RequestBrowserCompositorDisplay(",
                range: geometry.upperBound..<callbackBody.endIndex))
        let pendingNavigation = try XCTUnwrap(
            callbackBody.range(
                of: "browser->GetMainFrame()->LoadURL(",
                range: displayRequest.upperBound..<callbackBody.endIndex))

        XCTAssertLessThan(geometry.lowerBound, displayRequest.lowerBound)
        XCTAssertLessThan(displayRequest.lowerBound, pendingNavigation.lowerBound)

        let displayContract = String(
            callbackBody[geometry.lowerBound..<displayRequest.upperBound])
        XCTAssertFalse(displayContract.contains("LoadURL("))
        XCTAssertFalse(displayContract.contains("Reload()"))
        XCTAssertFalse(displayContract.contains("dispatch_after"))
        XCTAssertFalse(displayContract.contains("removeFromSuperview"))
        XCTAssertFalse(displayContract.contains("addSubview"))
        XCTAssertFalse(displayContract.contains("SetAsWindowless"))

        let loadMethod = try XCTUnwrap(
            source.range(of: "- (void)loadURLString:"))
        let loadEnd = try XCTUnwrap(
            source.range(
                of: "- (void)goBack",
                range: loadMethod.upperBound..<source.endIndex))
        let loadBody = String(
            source[loadMethod.lowerBound..<loadEnd.lowerBound])
        XCTAssertTrue(loadBody.contains(
            "browser->GetMainFrame()->LoadURL("))
        XCTAssertFalse(loadBody.contains("Reload()"))
        XCTAssertFalse(loadBody.contains("dispatch_after"))
        XCTAssertFalse(loadBody.contains("removeFromSuperview"))
        XCTAssertFalse(loadBody.contains("addSubview"))
        XCTAssertFalse(loadBody.contains("SetAsWindowless"))
    }

    func testCEFFirstFrameTelemetryIsNavigationScopedAndRejectsStalePresentation()
        throws
    {
        let source = try bridgeSource()
        XCTAssertTrue(source.contains(
            "uint64_t navigation_generation = 0"))
        XCTAssertTrue(source.contains(
            "uint64_t first_frame_presented_generation = 0"))
        XCTAssertFalse(source.contains(
            "bool first_frame_presented_logged"))

        let request = try XCTUnwrap(
            source.range(
                of: "void RequestBrowserCompositorDisplay(",
                options: .backwards))
        let requestEnd = try XCTUnwrap(
            source.range(
                of: "void PublishState(",
                range: request.upperBound..<source.endIndex))
        let requestBody = String(
            source[request.lowerBound..<requestEnd.lowerBound])
        XCTAssertTrue(requestBody.contains(
            "const uint64_t navigation_generation = "
                + "state->navigation_generation"))
        XCTAssertTrue(requestBody.contains(
            "state->first_frame_presented_generation !="
                + "\n          navigation_generation"))
        XCTAssertTrue(requestBody.contains(
            "presented_state->navigation_generation !="
                + "\n          navigation_generation"))
        XCTAssertTrue(requestBody.contains(
            "presented_state->first_frame_presented_generation ="
                + "\n          navigation_generation"))

        for (method, nextMethod, dispatchedCommand) in [
            ("- (void)loadURLString:", "- (void)goBack", "LoadURL("),
            ("- (void)goBack", "- (void)goForward", "GoBack()"),
            ("- (void)goForward", "- (void)reload", "GoForward()"),
            ("- (void)reload", "- (void)closeBrowser", "Reload()"),
        ] {
            let start = try XCTUnwrap(source.range(of: method))
            let end = try XCTUnwrap(
                source.range(
                    of: nextMethod,
                    range: start.upperBound..<source.endIndex))
            let body = String(source[start.lowerBound..<end.lowerBound])
            let reset = try XCTUnwrap(
                body.range(of: "BeginNavigationFrameTelemetry("))
            let dispatch = try XCTUnwrap(
                body.range(
                    of: dispatchedCommand,
                    range: reset.upperBound..<body.endIndex))
            XCTAssertLessThan(reset.lowerBound, dispatch.lowerBound, method)
        }
    }

    func testCEFMainFrameCompletionReissuesPinnedNativeDisplayContract()
        throws
    {
        let source = try bridgeSource()
        let request = try XCTUnwrap(
            source.range(
                of: "void RequestBrowserCompositorDisplay(",
                options: .backwards))
        let requestEnd = try XCTUnwrap(
            source.range(
                of: "void PublishState(",
                range: request.upperBound..<source.endIndex))
        let requestBody = String(
            source[request.lowerBound..<requestEnd.lowerBound])

        XCTAssertTrue(requestBody.contains(
            "child.superview != view"))
        XCTAssertTrue(requestBody.contains(
            "[child setNeedsDisplay:YES]"))
        XCTAssertTrue(requestBody.contains(
            "for (NSView *native_content_view in child.subviews)"))
        XCTAssertTrue(requestBody.contains(
            "[native_content_view setNeedsDisplay:YES]"))
        XCTAssertFalse(requestBody.contains("LoadURL("))
        XCTAssertFalse(requestBody.contains("Reload()"))
        XCTAssertFalse(requestBody.contains("removeFromSuperview"))
        XCTAssertFalse(requestBody.contains("addSubview"))
        XCTAssertFalse(requestBody.contains("dispatch_after"))

        let loadEnd = try XCTUnwrap(
            source.range(of: "void OnLoadEnd("))
        let addressChange = try XCTUnwrap(
            source.range(
                of: "void OnAddressChange(",
                range: loadEnd.upperBound..<source.endIndex))
        let loadEndBody = String(
            source[loadEnd.lowerBound..<addressChange.lowerBound])
        XCTAssertTrue(loadEndBody.contains("frame->IsMain()"))
        XCTAssertTrue(loadEndBody.contains(
            "RequestBrowserCompositorDisplay("))
        XCTAssertTrue(loadEndBody.contains(
            "@\"main_frame_load_end\""))

        let callback = try XCTUnwrap(
            source.range(of: "void TatwoClient::OnAfterCreated"))
        let callbackEnd = try XCTUnwrap(
            source.range(
                of: "void TatwoClient::OnBeforeClose",
                range: callback.upperBound..<source.endIndex))
        let callbackBody = String(
            source[callback.lowerBound..<callbackEnd.lowerBound])
        XCTAssertTrue(callbackBody.contains(
            "RequestBrowserCompositorDisplay("))
        XCTAssertTrue(callbackBody.contains(
            "@\"on_after_created\""))
    }

    func testCEFContainerLayerBacksExternalRootBeforeInstallingBrowser() throws {
        let source = try chromiumBackendSource()
        let install = try XCTUnwrap(
            source.range(of: "func install("))
        let layout = try XCTUnwrap(
            source.range(
                of: "override func layout()",
                range: install.upperBound..<source.endIndex))
        let body = String(source[install.lowerBound..<layout.lowerBound])
        let frame = try XCTUnwrap(body.range(of: "browserView.frame = bounds"))
        let autoresize = try XCTUnwrap(
            body.range(of: "browserView.autoresizingMask"))
        let attach = try XCTUnwrap(body.range(of: "addSubview(browserView)"))
        let containerLayer = try XCTUnwrap(
            body.range(of: "wantsLayer = true"))
        let browserLayer = try XCTUnwrap(
            body.range(of: "browserView.wantsLayer = true"))

        XCTAssertLessThan(containerLayer.lowerBound, attach.lowerBound)
        XCTAssertLessThan(browserLayer.lowerBound, attach.lowerBound)
        XCTAssertLessThan(frame.lowerBound, attach.lowerBound)
        XCTAssertLessThan(autoresize.lowerBound, attach.lowerBound)
        XCTAssertTrue(body.contains("browserView.isHidden = false"))
        XCTAssertTrue(body.contains(
            "logEmbeddingSnapshot(phase: \"container_before_install\""))
        XCTAssertTrue(body.contains(
            "logEmbeddingSnapshot(phase: \"container_after_install\""))
        XCTAssertTrue(source.contains("browserView.needsLayout = true"))
    }

    func testCEFWindowedHostKeepsCEFNativeChildOwnershipAndLogsGeometry()
        throws
    {
        let source = try bridgeSource()
        let geometry = try XCTUnwrap(
            source.range(of: "void SynchronizeBrowserGeometry("))
        let statePublisher = try XCTUnwrap(
            source.range(
                of: "void PublishState(",
                range: geometry.upperBound..<source.endIndex))
        let body = String(
            source[geometry.lowerBound..<statePublisher.lowerBound])

        XCTAssertTrue(body.contains("child.superview == view"))
        XCTAssertTrue(body.contains("child.frame = NSMakeRect(0, 0"))
        XCTAssertTrue(body.contains(
            "child.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable"))
        XCTAssertFalse(body.contains("[child removeFromSuperview]"))
        XCTAssertFalse(body.contains("[view addSubview:child]"))
        XCTAssertTrue(body.contains(
            "LogBrowserLifecycle(@\"child_parent_mismatch\")"))

        for field in [
            "parentWindow=",
            "parentWindowVisible=",
            "childClass=",
            "childParentMatches=",
            "childWindow=",
            "ancestry=",
            "subviews=",
        ] {
            XCTAssertTrue(source.contains(field), field)
        }
        XCTAssertTrue(source.contains(
            "settings.windowless_rendering_enabled = false"))
        XCTAssertTrue(source.contains(
            "Geometry-only diagnostics. Never include URL"))
    }

    func testCEFLifecycleTelemetryExcludesSessionDataAndReportsRendererExit()
        throws
    {
        let source = try bridgeSource()
        XCTAssertTrue(source.contains(
            "LogRendererTermination(status, error_code)"))
        XCTAssertTrue(source.contains(
            "lifecycle=renderer_terminated status=%d code=%d"))
        XCTAssertTrue(source.contains(
            "LogBrowserLifecycle(@\"create_rejected\")"))
        XCTAssertTrue(source.contains(
            "Lifecycle-only telemetry: never include URL, profile path, cookies"))
        XCTAssertTrue(source.contains(
            "never emit error_string because Chromium may include page-specific data"))
        XCTAssertFalse(source.contains(
            "NSLog(@\"[TatwoCEF] url="))
        XCTAssertFalse(source.contains(
            "NSLog(@\"[TatwoCEF] profile="))
        XCTAssertFalse(source.contains(
            "FromCefString(error_string)"))
    }

    func testCEFNavigationTraceIsMainFrameOnlyAndSessionAgnostic() throws {
        let source = try bridgeSource()
        let trace = try XCTUnwrap(
            source.range(of: "void LogBrowserNavigationTrace("))
        let renderer = try XCTUnwrap(
            source.range(
                of: "void LogRendererTermination(",
                range: trace.upperBound..<source.endIndex))
        let traceBody = String(source[trace.lowerBound..<renderer.lowerBound])

        for field in [
            "phase=navigation_trace",
            "event=%@",
            "sequence=%llu",
            "monotonicMs=%lld",
            "code=%ld",
            "isLoading=%d",
        ] {
            XCTAssertTrue(traceBody.contains(field), field)
        }
        XCTAssertTrue(traceBody.contains(
            "g_navigation_trace_sequence.fetch_add"))
        XCTAssertTrue(traceBody.contains(
            "AppendCEFEmbeddingTelemetryLine("))
        XCTAssertTrue(traceBody.contains(
            "Never include URL, page title, profile path"))
        for forbidden in [
            "GetURL(",
            "GetTitle(",
            "currentURLString",
            "pending_url",
            "persistent_profile",
            "error_text",
            "failed_url",
            "request->GetHeaderMap",
        ] {
            XCTAssertFalse(traceBody.contains(forbidden), forbidden)
        }

        for event in [
            "host_navigation_requested",
            "host_navigation_blocked",
            "browser_created",
            "main_navigation_allowed",
            "main_navigation_redirect_allowed",
            "main_navigation_blocked",
            "main_resource_allowed",
            "main_resource_blocked",
            "loading_state_changed",
            "main_frame_load_start",
            "main_frame_commit",
            "main_frame_load_end",
            "main_frame_load_error",
        ] {
            XCTAssertTrue(source.contains(
                "LogBrowserNavigationTrace("), event)
            XCTAssertTrue(source.contains("@\"\(event)\""), event)
        }

        let resource = try XCTUnwrap(
            source.range(
                of: "cef_return_value_t OnBeforeResourceLoad("))
        let resourceEnd = try XCTUnwrap(
            source.range(
                of: "private:",
                range: resource.upperBound..<source.endIndex))
        let resourceBody = String(
            source[resource.lowerBound..<resourceEnd.lowerBound])
        XCTAssertTrue(resourceBody.contains(
            "if (frame && frame->IsMain())"))

        let loadStart = try XCTUnwrap(
            source.range(of: "void OnLoadStart("))
        let loadEnd = try XCTUnwrap(
            source.range(
                of: "void OnLoadEnd(",
                range: loadStart.upperBound..<source.endIndex))
        let loadStartBody = String(
            source[loadStart.lowerBound..<loadEnd.lowerBound])
        XCTAssertTrue(loadStartBody.contains(
            "if (!frame || !frame->IsMain())"))
        XCTAssertTrue(loadStartBody.contains(
            "LogBrowserNavigationTrace(@\"main_frame_load_start\""))
    }

    func testCEFEmbeddingTelemetryUsesConfiguredAppendOnlySiblingFile()
        throws
    {
        let source = try bridgeSource()
        let configure = try XCTUnwrap(
            source.range(of: "void ConfigureCEFEmbeddingTelemetry("))
        let openDescriptor = try XCTUnwrap(
            source.range(
                of: "int OpenCEFEmbeddingTelemetryDescriptor(",
                range: configure.upperBound..<source.endIndex))
        let writeDescriptor = try XCTUnwrap(
            source.range(
                of: "void WriteCEFEmbeddingTelemetryPayloadToDescriptor(",
                range: openDescriptor.upperBound..<source.endIndex))
        let writePayload = try XCTUnwrap(
            source.range(
                of: "void WriteCEFEmbeddingTelemetryPayload(",
                range: writeDescriptor.upperBound..<source.endIndex))
        let payload = try XCTUnwrap(
            source.range(
                of: "NSData *CEFEmbeddingTelemetryPayload(",
                range: writePayload.upperBound..<source.endIndex))
        let append = try XCTUnwrap(
            source.range(
                of: "void AppendCEFEmbeddingTelemetryLine(",
                range: payload.upperBound..<source.endIndex))
        let lifecycle = try XCTUnwrap(
            source.range(
                of: "void LogBrowserLifecycle(",
                range: append.upperBound..<source.endIndex))
        let configureBody = String(
            source[configure.lowerBound..<openDescriptor.lowerBound])
        let openDescriptorBody = String(
            source[openDescriptor.lowerBound..<writeDescriptor.lowerBound])
        let writeDescriptorBody = String(
            source[writeDescriptor.lowerBound..<writePayload.lowerBound])
        let writePayloadBody = String(
            source[writePayload.lowerBound..<payload.lowerBound])
        let payloadBody = String(
            source[payload.lowerBound..<append.lowerBound])
        let appendBody = String(
            source[append.lowerBound..<lifecycle.lowerBound])
        let telemetryBody = String(
            source[configure.lowerBound..<lifecycle.lowerBound])

        XCTAssertTrue(configureBody.contains(
            "cef_log_file_path.stringByDeletingLastPathComponent"))
        XCTAssertTrue(configureBody.contains(
            "stringByAppendingPathComponent:@\"cef-embedding-telemetry.log\""))
        XCTAssertTrue(configureBody.contains(
            "!cef_log_file_path.isAbsolutePath"))
        XCTAssertFalse(configureBody.contains("/Users/"))
        XCTAssertFalse(configureBody.contains("/Volumes/"))

        XCTAssertTrue(source.contains("DISPATCH_QUEUE_SERIAL"))
        XCTAssertTrue(openDescriptorBody.contains(
            "O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC | O_NOFOLLOW"))
        XCTAssertTrue(openDescriptorBody.contains("S_ISREG(file_status.st_mode)"))
        XCTAssertFalse(telemetryBody.contains("O_TRUNC"))
        XCTAssertTrue(payloadBody.contains(
            "componentsSeparatedByCharactersInSet:newlines"))
        XCTAssertTrue(payloadBody.contains(
            "kCEFEmbeddingTelemetryMaximumLineLength"))
        XCTAssertTrue(openDescriptorBody.contains("if (descriptor < 0)"))
        XCTAssertTrue(writeDescriptorBody.contains("payload.length == 0"))
        XCTAssertTrue(writePayloadBody.contains("if (descriptor < 0)"))
        XCTAssertTrue(appendBody.contains("payload.length == 0"))

        let initializer = try XCTUnwrap(
            source.range(of: "+ (BOOL)initializeWithRootCachePath:"))
        let initializerEnd = try XCTUnwrap(
            source.range(
                of: "+ (void)clearDataForOrigin:",
                range: initializer.upperBound..<source.endIndex))
        let initializerBody = String(
            source[initializer.lowerBound..<initializerEnd.lowerBound])
        XCTAssertTrue(initializerBody.contains(
            "ConfigureCEFEmbeddingTelemetry(logFilePath)"))
    }

    func testCEFEmbeddingTelemetryIsGeometryOnlyAndHasRequiredPhases()
        throws
    {
        let source = try bridgeSource()
        let layerClass = try XCTUnwrap(
            source.range(of: "NSString *LayerClassName("))
        let snapshot = try XCTUnwrap(
            source.range(
                of: "void LogBrowserEmbeddingSnapshot(",
                range: layerClass.upperBound..<source.endIndex))
        let synchronize = try XCTUnwrap(
            source.range(
                of: "void SynchronizeBrowserGeometry(",
                range: snapshot.upperBound..<source.endIndex))
        let snapshotBody = String(
            source[snapshot.lowerBound..<synchronize.lowerBound])

        for field in [
            "phase=%@",
            "parentFrame=",
            "parentBounds=",
            "parentHidden=",
            "parentHiddenAncestor=",
            "parentWantsLayer=",
            "parentLayer=",
            "parentWindow=",
            "parentWindowNumber=",
            "childClass=",
            "childFrame=",
            "childBounds=",
            "childHidden=",
            "childHiddenAncestor=",
            "childWantsLayer=",
            "childLayer=",
            "childParentMatches=",
            "childWindow=",
            "childWindowNumber=",
            "ancestry=",
            "viewAncestry=",
            "subviews=",
            "directSubviewClasses=",
        ] {
            XCTAssertTrue(snapshotBody.contains(field), field)
        }
        for forbidden in [
            "GetURL(",
            "GetTitle(",
            "currentURLString",
            "pending_url",
            "persistent_profile",
            "state->pending_error",
        ] {
            XCTAssertFalse(snapshotBody.contains(forbidden), forbidden)
        }
        XCTAssertTrue(snapshotBody.contains(
            "Never include URL, profile paths, cookies"))
        XCTAssertTrue(snapshotBody.contains(
            "page titles, user text, or other session data"))
        XCTAssertTrue(snapshotBody.contains(
            "SanitizeTelemetryToken(phase, @\"unknown\")"))
        XCTAssertTrue(source.contains(
            "LogBrowserEmbeddingSnapshot(self, nullptr, @\"create_accepted\""))
        XCTAssertTrue(source.contains(
            "LogBrowserEmbeddingSnapshot(owner, browser, @\"on_after_created\""))
        XCTAssertTrue(source.contains("@\"on_after_created_500ms\""))
        XCTAssertTrue(source.contains(
            "LogBrowserEmbeddingSnapshot(self, state->browser, @\"layout\""))
        XCTAssertTrue(source.contains(
            "view, browser, @\"child_parent_mismatch\", true"))
    }

    func testCEFMessagePumpTelemetryIsBoundedAndLowFrequency() throws {
        let source = try bridgeSource()
        let summary = try XCTUnwrap(
            source.range(of: "void MaybeLogMessagePumpSummary("))
        let scheduler = try XCTUnwrap(
            source.range(
                of: "void ScheduleCEFMessagePumpWork(int64_t delay_ms) {",
                range: summary.upperBound..<source.endIndex))
        let summaryBody = String(
            source[summary.lowerBound..<scheduler.lowerBound])

        XCTAssertTrue(source.contains(
            "kCEFMessagePumpSummaryMinimumIntervalMilliseconds = 5000"))
        XCTAssertTrue(source.contains(
            "kCEFMessagePumpSummaryMinimumEventDelta = 128"))
        XCTAssertTrue(summaryBody.contains(
            "phase=message_pump_summary"))
        XCTAssertTrue(summaryBody.contains("scheduleCount=%llu"))
        XCTAssertTrue(summaryBody.contains("doWorkCount=%llu"))
        XCTAssertTrue(summaryBody.contains(
            "lastScheduleMonotonicMs=%lld"))
        XCTAssertTrue(summaryBody.contains(
            "lastDoWorkMonotonicMs=%lld"))
        XCTAssertTrue(summaryBody.contains(
            "requestedDelayMs=%lld"))
        XCTAssertTrue(summaryBody.contains(
            "normalizedDelayMs=%lld"))
        XCTAssertTrue(summaryBody.contains("generation=%llu"))
        XCTAssertTrue(summaryBody.contains(
            "event_count - previous_event_count"))
        XCTAssertTrue(summaryBody.contains(
            "now_ms - previous_summary_ms"))
        XCTAssertTrue(source.contains(
            "MaybeLogMessagePumpSummary(@\"schedule\")"))
        XCTAssertTrue(source.contains(
            "MaybeLogMessagePumpSummary(@\"do_work\")"))
    }

    func testCEFMacUsesDeclaredBaseHelperForOfficialRoleSpecificLookup()
        throws
    {
        let source = try bridgeSource()
        let initializer = try XCTUnwrap(
            source.range(of: "+ (BOOL)initializeWithRootCachePath:"))
        let initializerEnd = try XCTUnwrap(
            source.range(
                of: "+ (void)clearDataForOrigin:",
                range: initializer.upperBound..<source.endIndex))
        let body = String(
            source[initializer.lowerBound..<initializerEnd.lowerBound])

        XCTAssertTrue(body.contains(
            "ResolveCEFHelperExecutablePath(helperExecutablePath)"))
        XCTAssertTrue(body.contains(
            "CefString(&settings.browser_subprocess_path)"))
        XCTAssertTrue(body.contains(
            "ToCefString(resolved_helper_executable_path)"))
        XCTAssertTrue(body.contains(
            "Alerts/GPU/Plugin/Renderer"))
        XCTAssertTrue(source.contains(
            "helper_bundle.executablePath.stringByStandardizingPath"))
        XCTAssertTrue(source.contains(
            "NSBundle.mainBundle.privateFrameworksPath"))
        XCTAssertTrue(source.contains(
            "isExecutableFileAtPath:resolved_path"))
        XCTAssertTrue(source.contains(
            "stringByResolvingSymlinksInPath"))
        XCTAssertTrue(source.contains(
            "Chromium helper bundle or declared executable is unavailable"))
    }

    func testCEFMacApplicationAndMessagePumpFollowVendorContracts()
        throws
    {
        let source = try bridgeSource()

        XCTAssertTrue(source.contains(
            "#include \"include/cef_application_mac.h\""))
        XCTAssertTrue(source.contains(
            "@interface TatwoCEFApplication () <CefAppProtocol>"))
        XCTAssertTrue(source.contains(
            "CefScopedSendingEvent scoped_sending_event"))
        XCTAssertTrue(source.contains(
            "- (BOOL)isHandlingSendEvent"))
        XCTAssertTrue(source.contains(
            "- (void)setHandlingSendEvent:"))

        let scheduler = try XCTUnwrap(
            source.range(
                of: "void ScheduleCEFMessagePumpWork(int64_t delay_ms) {"))
        let helper = try XCTUnwrap(
            source.range(of: "template <typename Work>"))
        let browserApp = try XCTUnwrap(
            source.range(
                of: "class TatwoBrowserProcessApp",
                range: scheduler.upperBound..<source.endIndex))
        let body = String(source[scheduler.lowerBound..<browserApp.lowerBound])
        let helperBody = String(source[helper.lowerBound..<scheduler.lowerBound])
        XCTAssertTrue(body.contains(
            "g_message_pump_generation.fetch_add"))
        XCTAssertTrue(body.contains(
            "g_message_pump_generation.load"))
        XCTAssertTrue(helperBody.contains("gate.TryBegin()"))
        XCTAssertTrue(helperBody.contains("gate.EndAndTakeFollowUp()"))
        XCTAssertTrue(body.contains(
            "std::max<int64_t>(delay_ms, 0)"))
        // W60: replaceable DispatchSourceTimer deadlines, never dispatch_after polling.
        XCTAssertTrue(body.contains("INT64_MAX / NSEC_PER_MSEC - 250"))
        XCTAssertTrue(body.contains("delay <= maximum"))
        XCTAssertTrue(body.contains("dispatch_time(DISPATCH_TIME_NOW, delay * NSEC_PER_MSEC)"))
        XCTAssertTrue(body.contains("if (delay == 0)"))
        XCTAssertTrue(body.contains("dispatch_async(dispatch_get_main_queue(), ^{"))
        XCTAssertTrue(body.contains("dispatch_source_set_timer(g_w60_vendor_timer, deadline, DISPATCH_TIME_FOREVER"))
        XCTAssertTrue(body.contains("dispatch_get_main_queue()"))
        XCTAssertTrue(helperBody.contains(
            "NSCAssert(NSThread.isMainThread"))
        XCTAssertTrue(helperBody.contains("CefDoMessageLoopWork()"))
        XCTAssertTrue(body.contains(
            "RunCEFMessagePumpWorkOnMainThread()"))
        XCTAssertFalse(body.contains("std::clamp<int64_t>(delay_ms"))
        XCTAssertFalse(body.contains("delay_ms, 0, 33"))

        let handler = try XCTUnwrap(
            source.range(of: "void OnScheduleMessagePumpWork("))
        let handlerEnd = try XCTUnwrap(
            source.range(
                of: "private:",
                range: handler.upperBound..<source.endIndex))
        let handlerBody = String(
            source[handler.lowerBound..<handlerEnd.lowerBound])
        XCTAssertTrue(handlerBody.contains(
            "ScheduleCEFMessagePumpWork(delay_ms)"))
        XCTAssertFalse(handlerBody.contains("dispatch_after("))
    }

    func testCEFCommandLineHardeningIsBrowserProcessOnly() throws {
        let source = try bridgeSource()
        let handler = try XCTUnwrap(
            source.range(of: "void OnBeforeCommandLineProcessing("))
        let handlerEnd = try XCTUnwrap(
            source.range(
                of: "void OnScheduleMessagePumpWork(",
                range: handler.upperBound..<source.endIndex))
        let body = String(
            source[handler.lowerBound..<handlerEnd.lowerBound])

        let subprocessGuard = try XCTUnwrap(
            body.range(of: "if (!process_type.empty())"))
        let deniedSwitchLoop = try XCTUnwrap(
            body.range(of: "for (const char *switch_name"))
        let firstAppend = try XCTUnwrap(
            body.range(of: "command_line->AppendSwitch("))

        XCTAssertLessThan(subprocessGuard.lowerBound, deniedSwitchLoop.lowerBound)
        XCTAssertLessThan(subprocessGuard.lowerBound, firstAppend.lowerBound)
        XCTAssertTrue(body[subprocessGuard.lowerBound...].contains("return;"))
        XCTAssertFalse(body.contains("disable-network-service"))
        XCTAssertFalse(body.contains("NetworkServiceInProcess"))
        XCTAssertFalse(body.contains("no-sandbox"))
    }

    func testCEFStagingBuildLockIsOwnedAndRevisionBound() throws {
        let script = try source(
            relativePath: "../../script/build_staging_app.sh")

        XCTAssertTrue(script.contains(
            "BUILD_LOCK_OWNER_FILE=\"$BUILD_LOCK_DIR/owner-token\""))
        XCTAssertTrue(script.contains(
            "printf '%s\\n' \"$BUILD_LOCK_OWNER_TOKEN\" > "
                + "\"$BUILD_LOCK_OWNER_FILE\""))
        XCTAssertTrue(script.contains(
            "!= \"$BUILD_LOCK_OWNER_TOKEN\""))
        XCTAssertTrue(script.contains(
            "TATWO_REQUIRED_BRANCH"))
        XCTAssertTrue(script.contains(
            "TATWO_REQUIRED_HEAD"))
        XCTAssertTrue(script.contains(
            "verify_build_repo_anchor \"after_lock_acquisition\""))
        XCTAssertTrue(script.contains(
            "verify_build_repo_anchor \"before_lock_release\""))
        XCTAssertTrue(script.contains(
            "SWIFT_BUILD_ARGS=(--package-path \"$ROOT_DIR\" "
                + "-c debug --jobs 2)"))

        let acquisition = try XCTUnwrap(
            script.range(of: "\nacquire_build_lock\n"))
        let firstSwiftBuild = try XCTUnwrap(
            script.range(
                of: "swift build",
                range: acquisition.upperBound..<script.endIndex))
        XCTAssertLessThan(acquisition.lowerBound, firstSwiftBuild.lowerBound)

        let release = try XCTUnwrap(
            script.range(of: "release_build_lock() {"))
        let rollback = try XCTUnwrap(
            script.range(
                of: "rollback_reuse_swap() {",
                range: release.upperBound..<script.endIndex))
        let releaseBody = String(
            script[release.lowerBound..<rollback.lowerBound])
        XCTAssertTrue(releaseBody.contains(
            "verify_build_repo_anchor \"before_lock_release\""))
        XCTAssertTrue(releaseBody.contains(
            "owner_token=\"$(cat \"$BUILD_LOCK_OWNER_FILE\""))
        XCTAssertTrue(releaseBody.contains(
            "rm \"$BUILD_LOCK_OWNER_FILE\""))
        XCTAssertTrue(releaseBody.contains(
            "rmdir \"$BUILD_LOCK_DIR\""))
    }

    func testRealCEFMessagePumpDeduplicatesReentrantFollowUpWork()
        throws
    {
        guard TatwoCEFRuntime.compiled else {
            throw XCTSkip("real CEF bridge was not compiled")
        }

        let repeatedKickSelector = NSSelectorFromString(
            "messagePumpGateRepeatedKickProbe:")
        let repeatedKickMethod = try XCTUnwrap(
            class_getClassMethod(
                TatwoCEFRuntime.self,
                repeatedKickSelector))
        typealias RepeatedKickProbe = @convention(c) (
            AnyObject,
            Selector,
            UInt32
        ) -> UInt64
        let repeatedKickProbe = unsafeBitCast(
            method_getImplementation(repeatedKickMethod),
            to: RepeatedKickProbe.self)
        let encodedCounts = repeatedKickProbe(
            TatwoCEFRuntime.self,
            repeatedKickSelector,
            10_000)
        XCTAssertEqual(encodedCounts >> 32, 2)
        XCTAssertEqual(encodedCounts & 0xffff_ffff, 1)

        let lateBlockSelector = NSSelectorFromString(
            "messagePumpShutdownLateBlockProbe")
        let lateBlockMethod = try XCTUnwrap(
            class_getClassMethod(
                TatwoCEFRuntime.self,
                lateBlockSelector))
        typealias LateBlockProbe = @convention(c) (
            AnyObject,
            Selector
        ) -> UInt64
        let lateBlockProbe = unsafeBitCast(
            method_getImplementation(lateBlockMethod),
            to: LateBlockProbe.self)
        XCTAssertEqual(
            lateBlockProbe(
                TatwoCEFRuntime.self,
                lateBlockSelector),
            1)
    }

    func testRealCEFImmediateKickSurvivesNewerVendorSchedule()
        throws
    {
        guard TatwoCEFRuntime.compiled else {
            throw XCTSkip("real CEF bridge was not compiled")
        }

        let selector = NSSelectorFromString(
            "messagePumpImmediateInterleavingProbe")
        let method = try XCTUnwrap(
            class_getClassMethod(TatwoCEFRuntime.self, selector))
        typealias ImmediateInterleavingProbe = @convention(c) (
            AnyObject,
            Selector
        ) -> UInt64
        let probe = unsafeBitCast(
            method_getImplementation(method),
            to: ImmediateInterleavingProbe.self)
        let encodedCounts = probe(TatwoCEFRuntime.self, selector)

        XCTAssertEqual(
            encodedCounts >> 32,
            1,
            "the host kick must reach do-work before vendor cancellation")
        XCTAssertEqual(
            encodedCounts & 0xffff_ffff,
            1,
            "the newer vendor request remains separately scheduled")
    }

    func testRealCEFQueuedHostKickSurvivesNewerVendorSchedule()
        throws
    {
        guard TatwoCEFRuntime.compiled else {
            throw XCTSkip("real CEF bridge was not compiled")
        }

        let selector = NSSelectorFromString(
            "messagePumpQueuedHostKickProbe")
        let method = try XCTUnwrap(
            class_getClassMethod(TatwoCEFRuntime.self, selector))
        typealias QueuedHostKickProbe = @convention(c) (
            AnyObject,
            Selector
        ) -> UInt64
        let probe = unsafeBitCast(
            method_getImplementation(method),
            to: QueuedHostKickProbe.self)
        let encodedCounts = probe(TatwoCEFRuntime.self, selector)

        XCTAssertEqual(
            encodedCounts >> 32,
            1,
            "a queued host kick must still reach do-work after a newer vendor schedule")
        XCTAssertEqual(
            (encodedCounts >> 16) & 0xffff,
            1,
            "background host kicks should coalesce to one queued main-thread block")
        XCTAssertEqual(
            encodedCounts & 0xffff,
            1,
            "the newer vendor request remains separately scheduled")
    }

    func testRealCEFFirstScheduledPumpDeliversWorkAndEmitsDiscriminatingTimeline()
        throws
    {
        guard TatwoCEFRuntime.compiled else {
            throw XCTSkip("real CEF bridge was not compiled")
        }

        let selector = NSSelectorFromString(
            "messagePumpFirstScheduleDeliveryProbe")
        let method = try XCTUnwrap(
            class_getClassMethod(TatwoCEFRuntime.self, selector))
        typealias FirstScheduleDeliveryProbe = @convention(c) (
            AnyObject,
            Selector
        ) -> UInt64
        let probe = unsafeBitCast(
            method_getImplementation(method),
            to: FirstScheduleDeliveryProbe.self)
        let encodedCounts = probe(TatwoCEFRuntime.self, selector)

        XCTAssertEqual(
            encodedCounts >> 32,
            1,
            "the first vendor schedule should remain the active generation")
        XCTAssertEqual(
            encodedCounts & 0xffff_ffff,
            1,
            "the first active generation must deliver one do-work iteration")

        let source = try bridgeSource()
        for requiredTelemetry in [
            "phase=helper_process event=launch role=%@",
            "launchCount=%llu countScope=role launchMeaning=attempt_not_restart",
            "phase=helper_process event=spawn role=%@",
            "exitCode=%d signal=0",
            "phase=navigation_timeline event=%@",
            "mountGeneration=%llu staleCallbackDrops=%llu",
            "event=stale_callback_dropped",
            "@\"geometry_layer_ready\"",
            "@\"navigation_accepted\"",
            "@\"main_frame_commit\"",
            "@\"main_frame_load_end\"",
            "@\"first_frame_presented\"",
            "phase=message_pump_overdue event=recover",
            "phase=message_pump_detail event=do_work",
        ] {
            XCTAssertTrue(
                source.contains(requiredTelemetry),
                requiredTelemetry)
        }
    }

    func testRealCEFTwoImmediateSchedulesBothDeliverWithoutGenerationCancellation()
        throws
    {
        guard TatwoCEFRuntime.compiled else {
            throw XCTSkip("real CEF bridge was not compiled")
        }

        let selector = NSSelectorFromString(
            "messagePumpTwoImmediateSchedulesProbe")
        let method = try XCTUnwrap(
            class_getClassMethod(TatwoCEFRuntime.self, selector))
        typealias TwoImmediateSchedulesProbe = @convention(c) (
            AnyObject,
            Selector
        ) -> UInt64
        let probe = unsafeBitCast(
            method_getImplementation(method),
            to: TwoImmediateSchedulesProbe.self)
        let encodedCounts = probe(TatwoCEFRuntime.self, selector)

        XCTAssertEqual(
            encodedCounts >> 32,
            2,
            "two immediate callbacks remain two independent schedules")
        XCTAssertEqual(
            encodedCounts & 0xffff_ffff,
            2,
            "a newer immediate callback must not cancel the first queued tick")

        let source = try bridgeSource()
        let scheduler = try XCTUnwrap(
            source.range(
                of: "void ScheduleCEFMessagePumpWork(int64_t delay_ms) {"))
        let immediateScheduler = try XCTUnwrap(
            source.range(
                of: "void QueueImmediateCEFMessagePumpWorkOnMainQueue()",
                range: scheduler.upperBound..<source.endIndex))
        let body = String(
            source[scheduler.lowerBound..<immediateScheduler.lowerBound])
        XCTAssertTrue(body.contains("const uint64_t generation = delay > 0"))
        XCTAssertTrue(body.contains("if (delay == 0)"))
        XCTAssertTrue(body.contains("generation != g_message_pump_generation.load"))
        XCTAssertTrue(body.contains("W60CancelVendorTimers()"))

    }

    func testRealCEFLegacyLoadingGateCannotArmTimersInW60()
        throws
    {
        guard TatwoCEFRuntime.compiled else {
            throw XCTSkip("real CEF bridge was not compiled")
        }

        let selector = NSSelectorFromString(
            "messagePumpLoadingActiveLifecycleProbe")
        let method = try XCTUnwrap(
            class_getClassMethod(TatwoCEFRuntime.self, selector))
        typealias LoadingActiveLifecycleProbe = @convention(c) (
            AnyObject,
            Selector
        ) -> UInt64
        let probe = unsafeBitCast(
            method_getImplementation(method),
            to: LoadingActiveLifecycleProbe.self)
        let encoded = probe(TatwoCEFRuntime.self, selector)

        XCTAssertEqual(
            (encoded >> 48) & 0xffff,
            3,
            "legacy gate predicate still permits three ticks in isolation; W60 never arms its timer")
        XCTAssertEqual(
            (encoded >> 32) & 0xffff,
            0,
            "the active token must stop delivering after load-end/idle")
        XCTAssertEqual(
            (encoded >> 16) & 0xffff,
            1,
            "a later navigation must use a fresh active generation")
        XCTAssertEqual(
            encoded & 0xffff,
            0,
            "close and runtime shutdown must both stop the fresh generation")

        let source = try bridgeSource()
        // W60 keeps lifecycle calls for close fencing but removes both fixed cadences.
        XCTAssertFalse(source.contains("phase=message_pump_loading_fallback"))
        XCTAssertFalse(source.contains("ArmLoadingActiveMessagePumpTimer"))
        XCTAssertTrue(source.contains("phase=message_pump_overdue event=recover"))
        XCTAssertTrue(source.contains(
            "owner, mount_generation_, @\"main_frame_load_end\")"))
        XCTAssertTrue(source.contains(
            "owner_, mount_generation_, @\"main_frame_load_error\")"))
        XCTAssertTrue(source.contains(
            "self, state->mount_generation, @\"close_requested\")"))

        let browserState = try XCTUnwrap(
            source.range(of: "struct BrowserState {"))
        let fallback = try XCTUnwrap(
            source.range(
                of: "void StartLoadingActiveMessagePump(",
                range: browserState.upperBound..<source.endIndex))
        let closeDriver = try XCTUnwrap(
            source.range(
                of: "void CompleteBrowserClose(",
                range: fallback.upperBound..<source.endIndex))
        let fallbackBody = String(
            source[fallback.lowerBound..<closeDriver.lowerBound])
        XCTAssertTrue(fallbackBody.contains("IsActiveMountCallback"))
        XCTAssertFalse(fallbackBody.contains("timerWithTimeInterval"))
        XCTAssertFalse(fallbackBody.contains("RunCEFMessagePumpWorkOnMainThread()"))
        XCTAssertFalse(fallbackBody.contains("Reload()"))
        XCTAssertFalse(fallbackBody.contains("LoadURL("))
        XCTAssertFalse(fallbackBody.contains("while ("))
        XCTAssertFalse(fallbackBody.contains("dispatch_source_create"))
    }

    func testCEFHelperTelemetryIsPreLoaderSafeAndReusesPreSandboxDescriptor()
        throws
    {
        let source = try bridgeSource()
        let parser = try XCTUnwrap(
            source.range(of: "CEFHelperRoleTelemetry CurrentCEFHelperRole()"))
        let configure = try XCTUnwrap(
            source.range(
                of: "void ConfigureCEFHelperProcessTelemetry(",
                range: parser.upperBound..<source.endIndex))
        let parserBody = String(
            source[parser.lowerBound..<configure.lowerBound])
        XCTAssertTrue(parserBody.contains("*_NSGetArgc()"))
        XCTAssertTrue(parserBody.contains("*_NSGetArgv()"))
        XCTAssertFalse(parserBody.contains("CefCommandLine"))

        let complete = try XCTUnwrap(
            source.range(
                of: "int CompleteCEFHelperProcessTelemetry(",
                range: configure.upperBound..<source.endIndex))
        let configureBody = String(
            source[configure.lowerBound..<complete.lowerBound])
        XCTAssertTrue(configureBody.contains(
            "OpenCEFEmbeddingTelemetryDescriptor("))
        XCTAssertTrue(configureBody.contains(
            "g_helper_telemetry_descriptor"))

        let subprocess = try XCTUnwrap(
            source.range(of: "int TatwoCEFExecuteSubprocess(void)"))
        let subprocessBody = String(source[subprocess.lowerBound...])
        let parseRole = try XCTUnwrap(
            subprocessBody.range(of: "CurrentCEFHelperRole()"))
        let configureTelemetry = try XCTUnwrap(
            subprocessBody.range(
                of: "ConfigureCEFHelperProcessTelemetry(",
                range: parseRole.upperBound..<subprocessBody.endIndex))
        let sandbox = try XCTUnwrap(
            subprocessBody.range(
                of: "sandbox_context.Initialize(",
                range: configureTelemetry.upperBound..<subprocessBody.endIndex))
        let loadHelper = try XCTUnwrap(
            subprocessBody.range(
                of: "library_loader.LoadInHelper()",
                range: sandbox.upperBound..<subprocessBody.endIndex))
        let execute = try XCTUnwrap(
            subprocessBody.range(
                of: "CefExecuteProcess(",
                range: loadHelper.upperBound..<subprocessBody.endIndex))
        XCTAssertLessThan(parseRole.lowerBound, configureTelemetry.lowerBound)
        XCTAssertLessThan(configureTelemetry.lowerBound, sandbox.lowerBound)
        XCTAssertLessThan(sandbox.lowerBound, loadHelper.lowerBound)
        XCTAssertLessThan(loadHelper.lowerBound, execute.lowerBound)
        XCTAssertEqual(
            subprocessBody.components(
                separatedBy: "CompleteCEFHelperProcessTelemetry(").count - 1,
            3)

        XCTAssertTrue(source.contains(
            "O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC | O_NOFOLLOW"))
        XCTAssertTrue(source.contains("S_ISREG(file_status.st_mode)"))
        XCTAssertTrue(source.contains(
            "WriteCEFEmbeddingTelemetryPayloadToDescriptor("))
        XCTAssertFalse(source.contains(
            "CefCommandLine::CreateCommandLine()"))
    }

    func testCEFHostActionsKickOneImmediateMainThreadPumpWithoutCadence()
        throws
    {
        let source = try bridgeSource()
        let immediate = try XCTUnwrap(
            source.range(of: "void ScheduleImmediateCEFMessagePumpWork("))
        let browserApp = try XCTUnwrap(
            source.range(
                of: "class TatwoBrowserProcessApp",
                range: immediate.upperBound..<source.endIndex))
        let body = String(
            source[immediate.lowerBound..<browserApp.lowerBound])

        XCTAssertTrue(body.contains(
            "phase=message_pump_host_kick reason=%@"))
        XCTAssertTrue(body.contains(
            "DeliverImmediateMessagePumpWork("))
        XCTAssertTrue(body.contains("NSThread.isMainThread"))
        XCTAssertTrue(body.contains(
            "RunCEFMessagePumpWorkOnMainThread()"))
        XCTAssertTrue(body.contains(
            "QueueImmediateCEFMessagePumpWorkOnMainQueue()"))
        XCTAssertFalse(body.contains(
            "ScheduleCEFMessagePumpWork(0)"))
        XCTAssertFalse(body.contains("while ("))
        XCTAssertFalse(body.contains("dispatch_source_create"))
        XCTAssertFalse(body.contains("NSTimer"))

        let createAccepted = try XCTUnwrap(
            source.range(of: "LogBrowserLifecycle(@\"create_accepted\")"))
        let creationTimeout = try XCTUnwrap(
            source.range(
                of: "PublishCreationTimeoutIfPending(self)",
                range: createAccepted.upperBound..<source.endIndex))
        let createBody = String(
            source[createAccepted.lowerBound..<creationTimeout.upperBound])
        XCTAssertTrue(createBody.contains(
            "ScheduleImmediateCEFMessagePumpWork("
                + "@\"browser_create_accepted\")"))

        for expectedKick in [
            "@\"pending_navigation\"",
            "@\"navigation\"",
            "@\"go_back\"",
            "@\"go_forward\"",
            "@\"reload\"",
        ] {
            XCTAssertTrue(
                source.contains(
                    "ScheduleImmediateCEFMessagePumpWork("
                        + expectedKick + ")"),
                expectedKick)
        }

        let scheduler = try XCTUnwrap(
            source.range(
                of: "void ScheduleCEFMessagePumpWork(int64_t delay_ms) {"))
        let helper = try XCTUnwrap(
            source.range(of: "template <typename Work>"))
        let immediateScheduler = try XCTUnwrap(
            source.range(
                of: "void ScheduleImmediateCEFMessagePumpWork(",
                range: scheduler.upperBound..<source.endIndex))
        let schedulerBody = String(
            source[scheduler.lowerBound..<immediateScheduler.lowerBound])
        let helperBody = String(source[helper.lowerBound..<scheduler.lowerBound])
        XCTAssertTrue(schedulerBody.contains(
            "g_message_pump_generation.load"))
        XCTAssertTrue(schedulerBody.contains(
            "CanRunScheduledMessagePump("))
        XCTAssertTrue(helperBody.contains("if (!gate.TryBegin())"))
        XCTAssertTrue(helperBody.contains("gate.EndAndTakeFollowUp()"))
        let hostQueue = try XCTUnwrap(
            source.range(
                of: "void QueueImmediateCEFMessagePumpWorkOnMainQueue()"))
        let immediateKick = try XCTUnwrap(
            source.range(
                of: "void ScheduleImmediateCEFMessagePumpWork(",
                range: hostQueue.upperBound..<source.endIndex))
        XCTAssertLessThan(hostQueue.lowerBound, immediateKick.lowerBound)
        let hostQueueBody = String(
            source[hostQueue.lowerBound..<immediateKick.lowerBound])
        XCTAssertTrue(hostQueueBody.contains(
            "QueueImmediateMessagePumpWork("))
        XCTAssertTrue(hostQueueBody.contains(
            "dispatch_async(dispatch_get_main_queue()"))
        XCTAssertTrue(hostQueueBody.contains(
            "g_message_pump_host_kick_queue_gate.EndQueue()"))
        XCTAssertTrue(hostQueueBody.contains(
            "RunCEFMessagePumpWorkOnMainThread()"))
        XCTAssertFalse(hostQueueBody.contains(
            "CanRunScheduledMessagePump("))
        XCTAssertFalse(hostQueueBody.contains(
            "g_message_pump_generation"))
        let busyBranch = try XCTUnwrap(
            helperBody.range(
                of: "if (!gate.TryBegin())"))
        let mainThreadAssertion = try XCTUnwrap(
            helperBody.range(
                of: "NSCAssert(NSThread.isMainThread",
                range: busyBranch.upperBound..<helperBody.endIndex))
        XCTAssertFalse(
            helperBody[busyBranch.lowerBound..<mainThreadAssertion.lowerBound]
                .contains("ScheduleCEFMessagePumpWork("))
        XCTAssertLessThan(
            try XCTUnwrap(schedulerBody.range(
                of: "CanRunScheduledMessagePump("))
                .lowerBound,
            try XCTUnwrap(schedulerBody.range(
                of: "RunCEFMessagePumpWorkOnMainThread()"))
                .lowerBound)
    }

    func testBundleBuildersUseLinkedCEFCompatiblePrincipalClass()
        throws
    {
        for relativePath in [
            "../../script/build_staging_app.sh",
            "../../script/build_production_app.sh",
        ] {
            let script = try source(relativePath: relativePath)
            XCTAssertTrue(
                script.contains(
                    "APP_PRINCIPAL_CLASS=\"TatwoCEFApplication\""),
                relativePath)
            XCTAssertTrue(
                script.contains(
                    "<string>$APP_PRINCIPAL_CLASS</string>"),
                relativePath)
            XCTAssertFalse(
                script.contains(
                    "<key>NSPrincipalClass</key><string>NSApplication</string>"),
                relativePath)
        }

        let unavailable = try source(
            relativePath:
                "Sources/TatwoCEFBridge/TatwoCEFBridgeUnavailable.m")
        XCTAssertTrue(unavailable.contains(
            "@implementation TatwoCEFApplication"))
        XCTAssertTrue(unavailable.contains(
            "BOOL previousValue = _tatwoHandlingSendEvent"))
        XCTAssertTrue(unavailable.contains("@finally"))
    }

    func testStagingCEFPreparationUsesVerifiedContentAddressedCachesAndRejectsUnsafeInputs()
        throws
    {
        let staging = try source(
            relativePath: "../../script/build_staging_app.sh")
        XCTAssertTrue(staging.contains(
            #"source "$ROOT_DIR/scripts/tatwo-cef-bundle.sh""#))
        XCTAssertTrue(staging.contains("\n  prepare_cef_runtime\n"))
        XCTAssertTrue(staging.contains("--refresh-cef-index"))
        let script = try source(relativePath: "../../scripts/tatwo-cef-bundle.sh")
        XCTAssertTrue(script.contains("validate_cef_distribution_pin"))
        XCTAssertTrue(script.contains("allowed_hosts = {\"cef-builds.spotifycdn.com\"}"))
        XCTAssertTrue(script.contains("validate_cef_official_index"))
        XCTAssertTrue(script.contains("cef_index_receipt_matches_pin"))
        XCTAssertTrue(script.contains("write_cef_index_receipt"))
        XCTAssertTrue(
            script.contains(
                "index-verified-$CEF_OFFICIAL_INDEX_SHA1.receipt"))
        XCTAssertTrue(script.contains("\"indexSHA256\": index_sha256"))
        XCTAssertTrue(script.contains("--proto '=https'"))
        XCTAssertTrue(script.contains("--max-redirs 0"))
        XCTAssertFalse(script.contains("curl --fail --location"))
        XCTAssertTrue(script.contains("tar -tjf \"$CEF_ARCHIVE_PATH\""))
        XCTAssertTrue(script.contains("validate_cef_archive_entries"))
        XCTAssertTrue(script.contains("validate_extracted_cef_tree"))
        XCTAssertTrue(script.contains("CEF archive changed during validation/extraction"))
        XCTAssertTrue(
            script.contains(
                "vendor/cef/runtime/$CEF_ARCHIVE_SHA256"))
        XCTAssertTrue(script.contains("CEF_RUNTIME_MANIFEST"))
        XCTAssertTrue(script.contains("manifest.sha256"))
        XCTAssertTrue(script.contains("write_cef_tree_manifest"))
        XCTAssertTrue(script.contains("validate_cef_tree_manifest"))
        XCTAssertTrue(
            script.contains(
                "move the cache to Trash (`trash -- "))
        XCTAssertTrue(script.contains("import shlex"))
        XCTAssertTrue(
            script.contains(
                "shlex.quote(os.path.dirname(root))"))
        XCTAssertTrue(
            script.contains(
                "printf -v cef_runtime_cache_shell_quoted '%q'"))
        XCTAssertTrue(
            script.contains(
                "trash -- $cef_runtime_cache_shell_quoted"))
        XCTAssertFalse(
            script.contains(
                "trash $CEF_RUNTIME_CACHE_DIR"))
        XCTAssertEqual(
            script.components(separatedBy: "def collect(directory):").count - 1,
            1)
        XCTAssertTrue(script.contains(
            "process_cef_tree_manifest write"))
        XCTAssertTrue(script.contains(
            "process_cef_tree_manifest validate"))
        XCTAssertFalse(script.contains("delete the cache and rebuild"))
        XCTAssertTrue(script.contains("CEF_RUNTIME_CACHE=verified-reuse"))
        XCTAssertTrue(script.contains("CEF_WRAPPER_CACHE_KEY"))
        XCTAssertTrue(script.contains("archive-sha256=%s\\nflags=%s\\n"))
        XCTAssertTrue(script.contains("xcrun clang++ --version"))
        XCTAssertTrue(script.contains("xcrun --show-sdk-version"))
        XCTAssertTrue(
            script.contains("xargs -P 2 -S 4096 -I '{}'"),
            "long external-volume source paths must fit the xargs replacement buffer")
        XCTAssertTrue(
            script.contains("shasum -a 256 | cut -d \" \" -f 1"),
            "the per-source object key must not interpolate bash positional arguments into awk")
        XCTAssertTrue(
            script.contains(
                "build-cef/$CEF_ARCHIVE_SHA256/$CEF_WRAPPER_CACHE_KEY"))
        XCTAssertTrue(script.contains("CEF_WRAPPER_SHA256_PATH"))
        XCTAssertTrue(script.contains("CEF_WRAPPER_CACHE=verified-reuse"))
        XCTAssertTrue(script.contains("CEF_WRAPPER_CACHE=rebuilt"))
        XCTAssertFalse(
            script.contains(
                "freshly built CEF wrapper digest mismatch"))
    }

    func testCEFMacSandboxContextFollowsPinnedCEFContract() throws {
        let source = try bridgeSource()
        let subprocess = try XCTUnwrap(
            source.range(of: "int TatwoCEFExecuteSubprocess(void)"))
        let body = String(source[subprocess.lowerBound..<source.endIndex])

        XCTAssertTrue(body.contains(
            "CefScopedSandboxContext sandbox_context"))
        XCTAssertTrue(body.contains(
            "sandbox_context.Initialize(*_NSGetArgc(), *_NSGetArgv())"))
        XCTAssertTrue(body.contains(
            "CefScopedLibraryLoader library_loader"))
        XCTAssertTrue(body.contains("library_loader.LoadInHelper()"))
        XCTAssertTrue(body.contains(
            "CefExecuteProcess(main_args, application, nullptr)"))
        XCTAssertFalse(body.contains("--no-sandbox"))
    }

    func testCEFMacGeometryNotifiesExternalRootScreenInfoWithoutOSRResize()
        throws
    {
        let source = try bridgeSource()
        let synchronize = try XCTUnwrap(
            source.range(
                of: "void SynchronizeBrowserGeometry(",
                options: .backwards))
        let synchronizeEnd = try XCTUnwrap(
            source.range(
                of: "void RequestBrowserCompositorDisplay(",
                range: synchronize.upperBound..<source.endIndex))
        let body = String(
            source[synchronize.lowerBound..<synchronizeEnd.lowerBound])

        XCTAssertTrue(body.contains("if (child.superview == view)"))
        XCTAssertFalse(body.contains("[child removeFromSuperview]"))
        XCTAssertFalse(body.contains("[view addSubview:child]"))
        XCTAssertTrue(body.contains("child.frame = NSMakeRect(0, 0"))
        XCTAssertTrue(body.contains(
            "child.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable"))
        XCTAssertTrue(body.contains("child.hidden = NO"))
        XCTAssertFalse(body.contains("[child setNeedsDisplay:YES]"))
        XCTAssertTrue(body.contains(
            "LogBrowserLifecycle(@\"child_parent_mismatch\")"))
        XCTAssertTrue(body.contains("host->NotifyScreenInfoChanged()"))
        XCTAssertTrue(body.contains(
            "state->last_screen_info_signature"))
        XCTAssertTrue(source.contains(
            "NSWindowDidChangeScreenNotification"))
        XCTAssertTrue(source.contains(
            "NSWindowDidChangeBackingPropertiesNotification"))
        for prohibitedMethod in [
            "WasResized",
            "NotifyMoveOrResizeStarted",
        ] {
            XCTAssertFalse(
                containsCXXInvocation(
                    named: prohibitedMethod,
                    in: body),
                "\(prohibitedMethod) must not be invoked by windowed geometry synchronization")
            XCTAssertFalse(
                containsCXXInvocation(
                    named: prohibitedMethod,
                    in: source),
                "\(prohibitedMethod) must not be invoked anywhere in the windowed CEF bridge")
        }
    }

    func testCXXInvocationScannerHandlesFormattingAndIgnoresNonCode()
    {
        let invocationFixtures = [
            "host->WasResized();",
            "host -> WasResized ();",
            "host->WasResized\n(\n);",
            "browser->GetHost()->NotifyMoveOrResizeStarted /* gap */ ( );",
            "NotifyMoveOrResizeStarted\t(\n);",
        ]
        XCTAssertTrue(
            invocationFixtures.allSatisfy {
                containsCXXInvocation(
                    named: $0.contains("WasResized")
                        ? "WasResized"
                        : "NotifyMoveOrResizeStarted",
                    in: $0)
            })

        let nonCodeFixture = #"""
            // host -> WasResized ();
            /* host->NotifyMoveOrResizeStarted
               (
               );
            */
            const char *plain = "host->WasResized ();";
            NSString *objectiveC =
                @"NotifyMoveOrResizeStarted\n(\n);";
            const char *escaped =
                "ignored \" host->WasResized ();";
            const char *raw =
                R"tag(host -> NotifyMoveOrResizeStarted ())tag";
            """#
        XCTAssertFalse(
            containsCXXInvocation(
                named: "WasResized",
                in: nonCodeFixture))
        XCTAssertFalse(
            containsCXXInvocation(
                named: "NotifyMoveOrResizeStarted",
                in: nonCodeFixture))
    }

    func testCEFSessionRetargetUsesNonblockingCloseableAsyncCreation()
        throws
    {
        let source = try bridgeSource()
        let start = try XCTUnwrap(
            source.range(of: "- (void)startBrowserIfReady {"))
        let startEnd = try XCTUnwrap(
            source.range(
                of: "- (void)layout",
                range: start.upperBound..<source.endIndex))
        let startBody = String(
            source[start.lowerBound..<startEnd.lowerBound])
        let asynchronousCreate = try XCTUnwrap(
            startBody.range(
                of: "CefBrowserHost::CreateBrowser("))
        let accepted = try XCTUnwrap(
            startBody.range(
                of: "LogBrowserLifecycle(@\"create_accepted\")"))

        XCTAssertLessThan(asynchronousCreate.lowerBound, accepted.lowerBound)
        XCTAssertTrue(startBody.contains(
            "const bool create_accepted"))
        XCTAssertTrue(startBody.contains("if (!create_accepted)"))
        XCTAssertTrue(startBody.contains(
            "state->creation_pending = true"))
        let acceptedTail = String(startBody[accepted.lowerBound...])
        XCTAssertFalse(acceptedTail.contains(
            "state->creation_pending = false"))
        XCTAssertTrue(acceptedTail.contains(
            "PublishCreationTimeoutIfPending(self)"))
        XCTAssertFalse(startBody.contains(
            "CefBrowserHost::CreateBrowserSync("))
        XCTAssertFalse(startBody.contains("dispatch_sync("))
        XCTAssertFalse(startBody.contains("dispatch_semaphore"))
        XCTAssertFalse(startBody.contains("runMode:beforeDate:"))
        XCTAssertFalse(startBody.contains("while ("))

        let closeStart = try XCTUnwrap(
            source.range(of: "- (void)closeBrowserWithCompletion:"))
        let closeEnd = try XCTUnwrap(
            source.range(
                of: "@end",
                range: closeStart.upperBound..<source.endIndex))
        let closeBody = String(
            source[closeStart.lowerBound..<closeEnd.lowerBound])
        XCTAssertTrue(closeBody.contains(
            "if (state->browser || state->creation_pending)"))
        XCTAssertTrue(closeBody.contains(
            "[g_closing_views addObject:self]"))
        XCTAssertTrue(closeBody.contains(
            "DriveBrowserClose("))
        XCTAssertTrue(closeBody.contains(
            "CompleteBrowserClose(self, state)"))

        let afterCreatedStart = try XCTUnwrap(
            source.range(of: "void TatwoClient::OnAfterCreated("))
        let afterCreatedEnd = try XCTUnwrap(
            source.range(
                of: "void TatwoClient::OnBeforeClose(",
                range: afterCreatedStart.upperBound..<source.endIndex))
        let afterCreatedBody = String(
            source[afterCreatedStart.lowerBound..<afterCreatedEnd.lowerBound])
        XCTAssertTrue(afterCreatedBody.contains(
            "state->creation_pending = false"))
        XCTAssertTrue(afterCreatedBody.contains(
            "if (state->close_requested)"))
        XCTAssertTrue(afterCreatedBody.contains(
            "state->close_generation += 1"))
        XCTAssertTrue(afterCreatedBody.contains(
            "state->close_retry_attempt = 0"))
        XCTAssertTrue(afterCreatedBody.contains(
            "state->close_retry_scheduled = false"))
        XCTAssertTrue(afterCreatedBody.contains(
            "DriveBrowserClose("))

        let closeDriverStart = try XCTUnwrap(
            source.range(
                of: """
                void DriveBrowserClose(TatwoCEFBrowserView *view,
                                       BrowserState *state,
                                       uint64_t generation) {
                """))
        let closeDriverEnd = try XCTUnwrap(
            source.range(
                of: "NSString *ViewAncestry(",
                range: closeDriverStart.upperBound..<source.endIndex))
        let closeDriverBody = String(
            source[closeDriverStart.lowerBound..<closeDriverEnd.lowerBound])
        let armedWatchdog = try XCTUnwrap(
            closeDriverBody.range(
                of: "ScheduleBrowserCloseRetry(view, state, generation)"))
        let closeRequest = try XCTUnwrap(
            closeDriverBody.range(of: "CloseBrowser(true)"))
        XCTAssertLessThan(
            armedWatchdog.lowerBound,
            closeRequest.lowerBound)
        XCTAssertTrue(closeDriverBody.contains("CloseBrowser(true)"))
        XCTAssertTrue(closeDriverBody.contains(
            "ScheduleImmediateCEFMessagePumpWork("))
        XCTAssertTrue(closeDriverBody.contains(
            "state->close_retry_attempt >= kCEFBrowserCloseMaximumAttempts"))
        XCTAssertFalse(closeDriverBody.contains("CompleteBrowserClose("))

        let closeRetryStart = try XCTUnwrap(
            source.range(of: "void ScheduleBrowserCloseRetry("))
        let closeRetryEnd = try XCTUnwrap(
            source.range(
                of: "void DriveBrowserClose(",
                range: closeRetryStart.upperBound..<source.endIndex))
        let closeRetryBody = String(
            source[closeRetryStart.lowerBound..<closeRetryEnd.lowerBound])
        XCTAssertTrue(closeRetryBody.contains(
            "pending_create_close_failed_closed"))
        XCTAssertTrue(closeRetryBody.contains(
            "retry_state->client->AbandonPendingCreation()"))
        XCTAssertTrue(closeRetryBody.contains(
            "CompleteBrowserClose(retry_view, retry_state)"))

        XCTAssertTrue(afterCreatedBody.contains(
            "late_browser_closed_after_pending_timeout"))
        XCTAssertTrue(afterCreatedBody.contains(
            "browser->GetHost()->CloseBrowser(true)"))
        XCTAssertTrue(afterCreatedBody.contains(
            "late_browser_close_after_pending_timeout"))

        let beforeCloseStart = try XCTUnwrap(
            source.range(of: "void TatwoClient::OnBeforeClose("))
        let beforeCloseEnd = try XCTUnwrap(
            source.range(
                of: "class TatwoLambdaCompletion",
                range: beforeCloseStart.upperBound..<source.endIndex))
        let beforeCloseBody = String(
            source[beforeCloseStart.lowerBound..<beforeCloseEnd.lowerBound])
        XCTAssertTrue(beforeCloseBody.contains(
            "CompleteBrowserClose(owner, state)"))
        XCTAssertTrue(source.contains(
            "state->close_completed = true"))
        XCTAssertTrue(source.contains(
            "view->_cefState = nullptr"))
    }

    func testCEFStateContractPublishesCommittedURLPhaseStatusAndError()
        throws
    {
        let header = try source(
            relativePath:
                "Sources/TatwoCEFBridge/include/TatwoCEFBridge.h")
        for field in [
            "committedMainFrameURLString",
            "BOOL isLoading",
            "TatwoCEFBrowserPhase phase",
            "NSInteger httpStatusCode",
            "TatwoCEFBrowserErrorKind errorKind",
            "NSInteger errorCode",
        ] {
            XCTAssertTrue(header.contains(field), field)
        }

        let source = try bridgeSource()
        let publish = try XCTUnwrap(
            source.range(of: "void PublishStateNow("))
        let visibleError = try XCTUnwrap(
            source.range(
                of: "void PublishVisibleError(",
                range: publish.upperBound..<source.endIndex))
        let publishBody = String(
            source[publish.lowerBound..<visibleError.lowerBound])
        for field in [
            "state->committed_url",
            "state->is_loading",
            "state->phase",
            "state->http_status_code",
            "state->error_kind",
            "state->error_code",
            "state->pending_error",
        ] {
            XCTAssertTrue(publishBody.contains(field), field)
        }

        let mutate = try XCTUnwrap(
            source.range(of: "void MutateStateOnMain("))
        let loadStart = try XCTUnwrap(
            source.range(
                of: "void PublishMainFrameLoadStart(",
                range: mutate.upperBound..<source.endIndex))
        let errorMutationBody = String(
            source[mutate.lowerBound..<loadStart.lowerBound])
        XCTAssertTrue(errorMutationBody.contains(
            "mutation(state)"))
        XCTAssertTrue(errorMutationBody.contains(
            "PublishStateNow(view)"))
        XCTAssertFalse(errorMutationBody.contains(
            "PublishState(view)"))
    }

    func testCEFStateProjectionKeepsCompletedPageClearOfLateLoadingChip() {
        var projector = EmbeddedChromiumNavigationStateProjector()
        let url = "https://example.com/results"

        let completed = projector.project(
            committedMainFrameURLString: url,
            navigationGeneration: 7,
            canGoBack: true,
            canGoForward: false,
            isLoading: false,
            phase: .finished,
            httpStatusCode: 200,
            errorKind: .none,
            errorCode: 0,
            visibleError: nil)
        XCTAssertEqual(completed.phase, .finished)
        XCTAssertFalse(completed.isLoading)
        XCTAssertEqual(
            EmbeddedBrowserSurfacePresentation.condition(for: completed),
            .none)

        let lateSubresourceLoading = projector.project(
            committedMainFrameURLString: url,
            navigationGeneration: 7,
            canGoBack: true,
            canGoForward: false,
            isLoading: true,
            phase: .loading,
            httpStatusCode: 200,
            errorKind: .none,
            errorCode: 0,
            visibleError: nil)
        XCTAssertEqual(lateSubresourceLoading.phase, .finished)
        XCTAssertFalse(lateSubresourceLoading.isLoading)
        XCTAssertEqual(
            EmbeddedBrowserSurfacePresentation.condition(
                for: lateSubresourceLoading),
            .none)

        let sameURLMainFrameCommit = projector.project(
            committedMainFrameURLString: url,
            navigationGeneration: 8,
            canGoBack: true,
            canGoForward: false,
            isLoading: true,
            phase: .committed,
            httpStatusCode: 0,
            errorKind: .none,
            errorCode: 0,
            visibleError: nil)
        XCTAssertEqual(sameURLMainFrameCommit.phase, .committed)
        XCTAssertTrue(sameURLMainFrameCommit.isLoading)
        XCTAssertEqual(
            EmbeddedBrowserSurfacePresentation.condition(
                for: sameURLMainFrameCommit),
            .loadedAwaitingPaint)

        XCTAssertEqual(
            EmbeddedBrowserSurfacePresentation.condition(
                for: EmbeddedBrowserNavigationState(
                    urlString: url,
                    canGoBack: true,
                    canGoForward: false,
                    visibleError: nil,
                    isLoading: true,
                    phase: .finished,
                    committedMainFrameURLString: url,
                    httpStatusCode: 200)),
            .none)
    }

    func testCEFNavigationAbortDoesNotOverrideCurrentPage()
        throws
    {
        let source = try bridgeSource()
        let loadError = try XCTUnwrap(
            source.range(of: "void OnLoadError("))
        let renderer = try XCTUnwrap(
            source.range(
                of: "void OnRenderProcessTerminated(",
                range: loadError.upperBound..<source.endIndex))
        let body = String(source[loadError.lowerBound..<renderer.lowerBound])

        XCTAssertTrue(body.contains(
            "if (!frame || !frame->IsMain())"))
        XCTAssertTrue(body.contains(
            "if (error_code == ERR_ABORTED) {\n      return;\n    }"))
        XCTAssertFalse(body.contains(
            "error_code != ERR_ABORTED"))
        XCTAssertTrue(body.contains(
            "TatwoCEFBrowserErrorKindNavigation"))
        XCTAssertTrue(body.contains(
            "TatwoCEFBrowserPhaseNavigationFailed"))

        let resource = try XCTUnwrap(
            source.range(
                of: "cef_return_value_t OnBeforeResourceLoad("))
        let resourceEnd = try XCTUnwrap(
            source.range(
                of: "private:",
                range: resource.upperBound..<source.endIndex))
        let resourceBody = String(
            source[resource.lowerBound..<resourceEnd.lowerBound])
        XCTAssertTrue(resourceBody.contains(
            "if (frame && frame->IsMain())"))
        XCTAssertTrue(resourceBody.contains("return RV_CANCEL"))
    }

    func testCEFMountIdentityDoesNotDependOnCommandsOrNavigationState()
        throws
    {
        let backend = try chromiumBackendSource()
        XCTAssertTrue(backend.contains(
            "struct EmbeddedChromiumBrowserMountIdentity"))
        XCTAssertTrue(backend.contains(
            "let profile: EmbeddedBrowserRuntimeProfile"))
        XCTAssertTrue(backend.contains(
            "container.mountIdentity == context.coordinator.mountIdentity"))
        XCTAssertTrue(backend.contains(
            "command.id != context.coordinator.lastCommandID"))

        let view = try source(
            relativePath:
                "Sources/TatwoUltraworkMac/EmbeddedBrowserView.swift")
        XCTAssertTrue(view.contains(
            "EmbeddedChromiumBrowserMountIdentity("))
        XCTAssertTrue(view.contains("profile: browserProfile"))
        XCTAssertFalse(view.contains(".id(command"))
        XCTAssertFalse(view.contains(".id(navigationState"))
    }

    func testBrowserSurfaceDistinguishesCEFOperationalFailurePhases() {
        let security = EmbeddedBrowserNavigationError(
            kind: .security,
            code: -20,
            message: "blocked")
        let navigation = EmbeddedBrowserNavigationError(
            kind: .navigation,
            code: -3,
            message: "aborted")
        let renderer = EmbeddedBrowserNavigationError(
            kind: .renderer,
            code: 42,
            message: "stopped")

        XCTAssertEqual(
            EmbeddedBrowserSurfacePresentation.condition(
                for: EmbeddedBrowserNavigationState(
                    urlString: nil,
                    canGoBack: false,
                    canGoForward: false,
                    visibleError: .runtimeMessage("blocked"),
                    phase: .blockedBySecurity,
                    structuredError: security)),
            .blockedBySecurity(message: "blocked"))
        XCTAssertEqual(
            EmbeddedBrowserSurfacePresentation.condition(
                for: EmbeddedBrowserNavigationState(
                    urlString: nil,
                    canGoBack: false,
                    canGoForward: false,
                    visibleError: .runtimeMessage("aborted"),
                    phase: .navigationFailed,
                    structuredError: navigation)),
            .navigationFailure(message: "aborted", code: -3))
        XCTAssertEqual(
            EmbeddedBrowserSurfacePresentation.condition(
                for: EmbeddedBrowserNavigationState(
                    urlString: "https://example.com/",
                    canGoBack: false,
                    canGoForward: false,
                    visibleError: .runtimeMessage("stopped"),
                    phase: .rendererFailed,
                    structuredError: renderer)),
            .subprocessRestart(message: "stopped", code: 42))
        XCTAssertEqual(
            EmbeddedBrowserSurfacePresentation.condition(
                for: EmbeddedBrowserNavigationState(
                    urlString: nil,
                    canGoBack: false,
                    canGoForward: false,
                    visibleError: nil,
                    isLoading: true,
                    phase: .loading)),
            .pageCreating)
        XCTAssertEqual(
            EmbeddedBrowserSurfacePresentation.condition(for: .blank),
            .blankNoncommitted)
        XCTAssertEqual(
            EmbeddedBrowserSurfacePresentation.condition(
                for: EmbeddedBrowserNavigationState(
                    urlString: "https://example.com/not-found",
                    canGoBack: true,
                    canGoForward: false,
                    visibleError: nil,
                    phase: .finished,
                    httpStatusCode: 404)),
            .httpFailure(status: 404))
    }

    func testCEFProfileAccessRejectsCancelledOrRetargetedWaiterBeforeMount()
        throws
    {
        let source = try source(
            relativePath:
                "Sources/TatwoUltraworkMac/EmbeddedBrowserView.swift")
        let refreshStart = try XCTUnwrap(
            source.range(of: "private func refreshProfileAccess() async"))
        let refreshEnd = try XCTUnwrap(
            source.range(
                of: "private var browserToolbar",
                range: refreshStart.upperBound..<source.endIndex))
        let body = String(
            source[refreshStart.lowerBound..<refreshEnd.lowerBound])
        let reset = try XCTUnwrap(
            body.range(of: "clearSessionDerivedVisibleState()"))
        let retarget = try XCTUnwrap(
            body.range(of: "visibleProfileKey != profileKey"))
        let wait = try XCTUnwrap(
            body.range(of: ".recordAccessAndEnforce("))
        let cancellation = try XCTUnwrap(
            body.range(of: "guard !Task.isCancelled"))
        let identity = try XCTUnwrap(
            body.range(of: "browserProfile.registryKey == profileKey"))
        let ready = try XCTUnwrap(
            body.range(
                of: "profileAccessState = .ready(",
                range: cancellation.upperBound..<body.endIndex))

        XCTAssertLessThan(retarget.lowerBound, reset.lowerBound)
        XCTAssertLessThan(reset.lowerBound, wait.lowerBound)
        XCTAssertLessThan(wait.lowerBound, cancellation.lowerBound)
        XCTAssertLessThan(cancellation.lowerBound, ready.lowerBound)
        XCTAssertLessThan(identity.lowerBound, ready.lowerBound)

        let resetStart = try XCTUnwrap(
            source.range(
                of: "private func clearSessionDerivedVisibleState()"))
        let resetEnd = try XCTUnwrap(
            source.range(
                of: "private var browserToolbar",
                range: resetStart.upperBound..<source.endIndex))
        let resetBody = String(
            source[resetStart.lowerBound..<resetEnd.lowerBound])
        XCTAssertTrue(resetBody.contains(
            "clearActivePageVisibleState()"))
        XCTAssertTrue(body.contains(
            "browserEngine == .chromiumUnavailable"))
        XCTAssertTrue(body.contains(
            "clearActivePageVisibleState()"))

        let activePageResetStart = try XCTUnwrap(
            source.range(
                of: "private func clearActivePageVisibleState()"))
        let activePageResetEnd = try XCTUnwrap(
            source.range(
                of: "private var browserToolbar",
                range: activePageResetStart.upperBound..<source.endIndex))
        let activePageResetBody = String(
            source[
                activePageResetStart.lowerBound
                    ..< activePageResetEnd.lowerBound
            ])
        for clearedState in [
            "addressText = \"\"",
            "canGoBack = false",
            "canGoForward = false",
            "currentURLString = \"\"",
            "showAnnotations = false",
        ] {
            XCTAssertTrue(
                activePageResetBody.contains(clearedState),
                clearedState)
        }
        for clearedSessionState in [
            "command = nil",
            "validationMessage = nil",
            "navigationState = .blank",
            "profileMaintenanceMessage = nil",
        ] {
            XCTAssertTrue(
                resetBody.contains(clearedSessionState),
                clearedSessionState)
        }

        let applyStart = try XCTUnwrap(
            source.range(of: "private func applyNavigationState("))
        let applyEnd = try XCTUnwrap(
            source.range(
                // applyNavigationState closes EmbeddedBrowserView.swift since the
                // 2026-09-02 split; the family reader joins the next file after it.
                of: "\n}\n\nimport ",
                range: applyStart.upperBound..<source.endIndex))
        let applyBody = String(
            source[applyStart.lowerBound..<applyEnd.lowerBound])
        XCTAssertTrue(applyBody.contains(
            "EmbeddedBrowserActivePageRetentionPolicy"))
        XCTAssertTrue(applyBody.contains(
            ".shouldClearActivePage(for: state)"))
        XCTAssertTrue(applyBody.contains(
            "clearActivePageVisibleState()"))
        XCTAssertTrue(applyBody.contains(
            "else if let urlString = state.urlString"))
    }

    private func containsCXXInvocation(
        named methodName: String,
        in source: String
    ) -> Bool {
        let tokens = cxxLexicalTokens(in: source)
        guard tokens.count >= 2 else { return false }
        return tokens.indices.dropLast().contains {
            tokens[$0] == methodName && tokens[$0 + 1] == "("
        }
    }

    private func cxxLexicalTokens(in source: String) -> [String] {
        let bytes = Array(source.utf8)
        var tokens: [String] = []
        var index = 0

        func isIdentifierStart(_ byte: UInt8) -> Bool {
            byte == 95
                || (65...90).contains(byte)
                || (97...122).contains(byte)
        }

        func isIdentifierContinuation(_ byte: UInt8) -> Bool {
            isIdentifierStart(byte) || (48...57).contains(byte)
        }

        func rawStringPrefixLength(at offset: Int) -> Int? {
            for prefix in [
                Array(#"u8R""#.utf8),
                Array(#"uR""#.utf8),
                Array(#"UR""#.utf8),
                Array(#"LR""#.utf8),
                Array(#"R""#.utf8),
            ] where offset + prefix.count <= bytes.count {
                if Array(bytes[offset..<(offset + prefix.count)])
                    == prefix
                {
                    return prefix.count
                }
            }
            return nil
        }

        func endOfRawString(
            startingAt offset: Int,
            prefixLength: Int
        ) -> Int {
            let delimiterStart = offset + prefixLength
            guard delimiterStart <= bytes.count,
                  let openParenthesis = bytes[
                    delimiterStart..<bytes.count
                  ].firstIndex(of: 40)
            else {
                return bytes.count
            }
            let delimiter = Array(
                bytes[delimiterStart..<openParenthesis])
            var cursor = openParenthesis + 1
            while cursor < bytes.count {
                guard bytes[cursor] == 41 else {
                    cursor += 1
                    continue
                }
                let delimiterEnd = cursor + 1 + delimiter.count
                guard delimiterEnd < bytes.count,
                      Array(bytes[(cursor + 1)..<delimiterEnd])
                        == delimiter,
                      bytes[delimiterEnd] == 34
                else {
                    cursor += 1
                    continue
                }
                return delimiterEnd + 1
            }
            return bytes.count
        }

        while index < bytes.count {
            let byte = bytes[index]
            if byte == 32 || byte == 9 || byte == 10 || byte == 13 {
                index += 1
                continue
            }
            if index + 1 < bytes.count,
               byte == 47,
               bytes[index + 1] == 47
            {
                index += 2
                while index < bytes.count, bytes[index] != 10 {
                    index += 1
                }
                continue
            }
            if index + 1 < bytes.count,
               byte == 47,
               bytes[index + 1] == 42
            {
                index += 2
                while index + 1 < bytes.count,
                      !(bytes[index] == 42
                        && bytes[index + 1] == 47)
                {
                    index += 1
                }
                index = min(index + 2, bytes.count)
                continue
            }
            if let prefixLength = rawStringPrefixLength(at: index) {
                index = endOfRawString(
                    startingAt: index,
                    prefixLength: prefixLength)
                continue
            }
            if byte == 34 || byte == 39 {
                let quote = byte
                index += 1
                while index < bytes.count {
                    if bytes[index] == 92 {
                        index = min(index + 2, bytes.count)
                    } else if bytes[index] == quote {
                        index += 1
                        break
                    } else {
                        index += 1
                    }
                }
                continue
            }
            if isIdentifierStart(byte) {
                let start = index
                index += 1
                while index < bytes.count,
                      isIdentifierContinuation(bytes[index])
                {
                    index += 1
                }
                tokens.append(
                    String(decoding: bytes[start..<index], as: UTF8.self))
                continue
            }
            if index + 1 < bytes.count,
               (byte == 45 && bytes[index + 1] == 62
                || byte == 58 && bytes[index + 1] == 58)
            {
                tokens.append(
                    String(
                        decoding: bytes[index...(index + 1)],
                        as: UTF8.self))
                index += 2
                continue
            }
            if byte == 40 || byte == 41 || byte == 46 {
                tokens.append(
                    String(decoding: [byte], as: UTF8.self))
            }
            index += 1
        }
        return tokens
    }

    private func bridgeSource() throws -> String {
        try source(
            relativePath: "Sources/TatwoCEFBridge/TatwoCEFBridge.mm")
    }

    private func chromiumBackendSource() throws -> String {
        try source(
            relativePath:
                "Sources/TatwoUltraworkMac/ChromiumCEFBackend.swift")
    }

    private func source(relativePath: String) throws -> String {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try ChatSourceFamily.read(url: packageRoot.appendingPathComponent(relativePath))
    }
}
