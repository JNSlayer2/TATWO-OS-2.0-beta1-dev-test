import XCTest
@testable import TatwoUltraworkCore

// 2026-08-23 使用者「先問我」實測回歸鎖：內建工具權限請求（無 mcp__ 字樣）
// 也必須被偵測，否則一鍵放行鈕永遠不出現。
final class ChatMCPApprovalRequestTests: XCTestCase {
    func testDetectsBuiltinWritePermissionRequest() {
        let text = "Claude requested permissions to write to /Users/example/y/test.md, "
            + "but you haven't granted it yet."
        let request = TatwoChatMCPApprovalRequest(diagnosticText: text)
        XCTAssertEqual(request?.toolName, "Write")
    }

    func testDetectsBuiltinUseToolPermissionRequest() {
        let text = "Claude requested permissions to use Bash, but you haven't granted it yet."
        let request = TatwoChatMCPApprovalRequest(diagnosticText: text)
        XCTAssertEqual(request?.toolName, "Bash")
    }

    func testStillDetectsMCPToolRequest() {
        let text = "permission required for mcp__tatwo-app__tatwo_app_switch_tab"
        let request = TatwoChatMCPApprovalRequest(diagnosticText: text)
        XCTAssertEqual(request?.toolName, "mcp__tatwo-app__tatwo_app_switch_tab")
    }

    func testPlainTextDoesNotTriggerApproval() {
        XCTAssertNil(TatwoChatMCPApprovalRequest(
            diagnosticText: "檔案已建立，內容一行 hello。"))
    }
}
