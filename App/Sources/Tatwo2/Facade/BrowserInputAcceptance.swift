import AppKit
import Foundation

enum BrowserInputAcceptance {
    static func run() -> Bool {
        var passed = 0, failed = 0
        func check(_ label: String, _ ok: Bool) {
            if ok { passed += 1 } else { failed += 1 }
            print("BROWSERINPUTTEST \(ok ? "PASS" : "FAIL") \(label)")
        }
        let fields: [[String: Any]] = [
            ["elementID":"cef-10", "label":"Name"],
            ["elementID":"cef-11", "label":"Email"],
            ["elementID":"cef-12", "label":"Backup Email"],
        ]
        func select(_ selector: String?, _ label: String?, _ source: [[String: Any]]? = nil) -> String? {
            BrowserAgentBridge.uniqueElement(source ?? fields, selector: selector, label: label)?["elementID"] as? String
        }
        check("exact later field does not fall back to first form field", select("cef-11", nil) == "cef-11")
        check("last field can be targeted", select("cef-12", nil) == "cef-12")
        check("exact identity wins over conflicting text", select("cef-10", "Email") == "cef-10")
        check("exact label wins over partial match", select(nil, "email") == "cef-11")
        check("unique partial label remains usable", select(nil, "backup") == "cef-12")
        check("empty selector and label never select first field", select(" ", " ") == nil)
        check("unknown field returns absent", select("cef-99", nil) == nil)
        check("ambiguous substring does not guess", select(nil, "mail") == nil)
        check("duplicate exact IDs do not guess", select("cef-10", nil, fields + [fields[0]]) == nil)
        check("duplicate exact labels do not guess", select(nil, "Name", fields + [["elementID":"cef-15", "label":"name"]]) == nil)
        let viewport: [String: Any] = ["width":200, "height":100]
        let size = NSSize(width:200, height:100)
        func point(_ rect: [String: Any], _ current: NSSize? = nil) -> NSPoint? {
            BrowserAgentBridge.clickPoint(rect: rect, viewport: viewport, size: current ?? size)
        }
        let rect: [String: Any] = ["x":10, "y":20, "width":40, "height":20]
        check("CEF coordinates remain top-left based", point(rect) == NSPoint(x:30,y:30))
        check("partly offscreen control uses visible rectangle", point(["x":-30,"y":20,"width":40,"height":20]) == NSPoint(x:5,y:30))
        check("fully offscreen control rejected", point(["x":210,"y":20,"width":40,"height":20]) == nil)
        check("zero width rejected", point(["x":10,"y":20,"width":0,"height":20]) == nil)
        check("negative height rejected", point(["x":10,"y":20,"width":40,"height":-1]) == nil)
        check("nonfinite rectangle rejected", point(["x":Double.nan,"y":20,"width":40,"height":20]) == nil)
        check("infinite rectangle rejected", point(["x":10,"y":20,"width":Double.infinity,"height":20]) == nil)
        check("missing geometry rejected", point(["x":10,"y":20,"height":20]) == nil)
        check("resized viewport invalidates click geometry", point(rect, NSSize(width:210,height:100)) == nil)
        check("empty viewport rejected", point(rect, .zero) == nil)
        check("nonfinite viewport rejected", point(rect, NSSize(width:Double.infinity,height:100)) == nil)
        check("normal wheel delta retained", BrowserAgentBridge.nativeScrollDelta(120) == 120)
        check("negative wheel delta retained", BrowserAgentBridge.nativeScrollDelta(-120) == -120)
        check("huge positive wheel does not overflow", BrowserAgentBridge.nativeScrollDelta(Int.max) == Int32.max)
        check("huge negative wheel remains safely negatable", BrowserAgentBridge.nativeScrollDelta(Int.min) == -Int32.max)
        print("BROWSERINPUTTEST RESULT passed=\(passed) failed=\(failed) skipped=0")
        return failed == 0
    }
}
