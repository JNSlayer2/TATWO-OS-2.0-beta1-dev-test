import Foundation

enum BrowserMetadataAcceptance {
    static func run() -> Bool {
        var passed = 0, failed = 0
        func check(_ label: String, _ ok: Bool) {
            if ok { passed += 1 } else { failed += 1 }
            print("BROWSERMETADATATEST \(ok ? "PASS" : "FAIL") \(label)")
        }
        let snapshot: [String: Any] = [
            "title": "Fixture form",
            "blocks": [
                ["text": "Page content", "quarantined": false],
                ["text": "QUARANTINED_SECRET", "quarantined": true],
                ["text": "LOW_CONTRAST_SECRET", "lowContrast": true],
            ],
            "controls": [
                ["elementID": "cef-20", "kind": "button", "label": "Sign in",
                 "value": "CONTROL_SECRET", "rect": ["x": 10]],
                ["elementID": "cef-21", "kind": "button", "label": "Disabled", "disabled": true],
            ],
            "forms": [
                ["elementID": "cef-10", "fields": [
                    ["elementID": "cef-11", "type": "text", "label": "Name", "value": "FIELD_SECRET"],
                    ["elementID": "cef-12", "type": "password", "label": "Password", "sensitive": true],
                    ["elementID": "cef-13", "type": "text", "label": "Read only", "readOnly": true],
                    ["elementID": "cef-20", "type": "submit", "label": "Sign in"],
                ]],
            ],
            "links": [
                ["elementID": "cef-30", "label": "Help", "destinationPath": "/help"],
                ["elementID": "text-3", "label": "Not an actionable ID"],
                ["elementID": "cef-0", "label": "Invalid zero"],
                ["elementID": "cef-2147483648", "label": "Overflow"],
                ["elementID": "cef-001", "label": "Noncanonical"],
            ],
            "cookies": "COOKIE_SECRET",
            "riskFlags": ["truncated"],
        ]
        let read = BrowserAgentBridge.readSnapshot(
            snapshot, url: "https://example.com/login?code=URL_SECRET#token=FRAGMENT_SECRET", maxChars: 8000)
        let elements = read["elements"] as? [[String: Any]] ?? []
        let json = String(data: try! JSONSerialization.data(withJSONObject: read), encoding: .utf8)!
        check("page title remains title rather than first text block", read["title"] as? String == "Fixture form")
        check("only accepted visible text is returned", read["text"] as? String == "Page content")
        check("password metadata retained without its value", elements.contains {
            $0["selector"] as? String == "cef-12" && $0["sensitive"] as? Bool == true
        })
        check("read-only and disabled metadata are explicit", elements.contains {
            $0["selector"] as? String == "cef-13" && $0["readOnly"] as? Bool == true
        } && elements.contains {
            $0["selector"] as? String == "cef-21" && $0["disabled"] as? Bool == true
        })
        check("no values cookies quarantined text or auth query leak", !json.contains("SECRET"))
        check("no raw DOM geometry or destination metadata forwarded", !json.contains("rect") && !json.contains("destinationPath"))
        check("control shared with form is listed exactly once",
              elements.filter { $0["selector"] as? String == "cef-20" }.count == 1)
        check("invalid or invented selectors are omitted", elements.count == 6)
        check("source truncation remains visible", (read["truncated"] as? [String: Bool])?["snapshot"] == true)
        let clickables = BrowserAgentBridge.clickElements(snapshot)
        check("click route includes real buttons and links", clickables.count == 2)
        check("visible button can be selected by label",
              BrowserAgentBridge.uniqueElement(clickables, selector: nil, label: "Sign in")?["elementID"] as? String == "cef-20")
        check("disabled control cannot be selected",
              BrowserAgentBridge.uniqueElement(clickables, selector: "cef-21", label: nil) == nil)
        var large: [String: Any] = [
            "blocks": [["text": String(repeating: "文", count: 2000)]],
            "controls": (1...100).map { ["elementID": "cef-\($0)", "kind": "button", "label": String(repeating: "🐱", count: 300)] },
        ]
        for budget in [1, 100, 8000, 50000] {
            let result = BrowserAgentBridge.readSnapshot(large, url: "https://example.com/", maxChars: budget)
            let items = result["elements"] as? [[String: Any]] ?? []
            let metadataLength = items.reduce(0) {
                $0 + String(data: try! JSONSerialization.data(withJSONObject: $1, options: [.sortedKeys]), encoding: .utf8)!.count + 1
            }
            check("text plus metadata respects budget \(budget)",
                  (result["text"] as? String ?? "").count + metadataLength <= budget && items.count <= 64)
        }
        large["blocks"] = []
        let limited = BrowserAgentBridge.readSnapshot(large, url: "", maxChars: 50000)
        check("count budget has explicit truncation", (limited["truncated"] as? [String: Bool])?["elements"] == true)
        check("URL credentials and callback secrets removed",
              BrowserAgentBridge.pageDisplayURL("https://user:secret@example.com:8443/login?code=x#token=y") == "https://example.com:8443/login")
        check("non-page URL is not echoed", BrowserAgentBridge.pageDisplayURL("javascript:secret") == "")
        check("query-free public page URL retained", BrowserAgentBridge.pageDisplayURL("https://example.com/chart/") == "https://example.com/chart/")
        print("BROWSERMETADATATEST RESULT passed=\(passed) failed=\(failed) skipped=0")
        return failed == 0
    }
}
