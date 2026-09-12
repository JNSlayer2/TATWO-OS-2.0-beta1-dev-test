// 用法：swift scripts/tatwo2-ui-compare.swift <a.png> <b.png> [容忍百分比，預設 3]
// 印出兩張圖的平均像素差異百分比（0 = 完全一樣）。尺寸不同會先把 b 縮放到 a 的尺寸再比。
import Foundation
import AppKit

func rgba(_ url: URL, size: CGSize? = nil) -> (w: Int, h: Int, bytes: [UInt8])? {
    guard let img = NSImage(contentsOf: url), var cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
    var w = cg.width, h = cg.height
    if let size, (Int(size.width) != w || Int(size.height) != h) {
        w = Int(size.width); h = Int(size.height)
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        cg = ctx.makeImage()!
    }
    var bytes = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    return (w, h, bytes)
}

let args = CommandLine.arguments
guard args.count >= 3 else { print("用法：tatwo2-ui-compare.swift a.png b.png [容忍%]"); exit(2) }
guard let a = rgba(URL(fileURLWithPath: args[1])) else { print("讀不到 \(args[1])"); exit(2) }
guard let b = rgba(URL(fileURLWithPath: args[2]), size: CGSize(width: a.w, height: a.h)) else { print("讀不到 \(args[2])"); exit(2) }
let tol = args.count >= 4 ? Double(args[3]) ?? 3 : 3
var total: Double = 0
var changed = 0
let n = a.w * a.h
for i in 0..<n {
    let o = i * 4
    let d = abs(Int(a.bytes[o]) - Int(b.bytes[o])) + abs(Int(a.bytes[o+1]) - Int(b.bytes[o+1])) + abs(Int(a.bytes[o+2]) - Int(b.bytes[o+2]))
    total += Double(d) / (3 * 255)
    if d > 3 * 24 { changed += 1 }
}
let mean = total / Double(n) * 100
let changedPct = Double(changed) / Double(n) * 100
let ok = mean <= tol
print(String(format: "平均差異 %.2f%%  明顯不同的像素 %.2f%%  %@（容忍 %.1f%%）", mean, changedPct, ok ? "PASS" : "FAIL", tol))
exit(ok ? 0 : 1)
