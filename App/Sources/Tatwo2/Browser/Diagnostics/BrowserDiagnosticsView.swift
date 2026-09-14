import SwiftUI
import AppKit

@MainActor
struct BrowserDiagnosticsView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var diagnostics: BrowserDiagnostics

    init(registry: BrowserTabRegistry? = nil) {
        _diagnostics = StateObject(wrappedValue: BrowserDiagnostics(registry: registry))
    }

    var body: some View {
        VStack(spacing: BrowserSidebarMetrics.laneRowSpacing) {
            HStack {
                Text("瀏覽器診斷").font(.headline)
                Spacer()
                Button("複製診斷報告", action: copyReport)
                    .disabled(diagnostics.report.processes.isEmpty)
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: BrowserSidebarMetrics.laneRowSpacing) {
                    BrowserDiagnosticsCard(title: "引擎") {
                        Text(diagnostics.report.version)
                        Text(diagnostics.report.engine)
                        Text("DRM 影片（Widevine）：不支援")
                        Text(BrowserProcessHealth.codecLimitation)
                        Text(BrowserProcessHealth.touchIDLimitation)
                        Text("第一個 lease → 引擎 ready：\(diagnostics.report.startupText)")
                        Text("背景睡眠門檻：\(diagnostics.report.sleepText)")
                        Text("記憶體警告：\(String(format: "%.0f", diagnostics.report.memoryWarningMB)) MB")
                    }
                    BrowserDiagnosticsCard(title: "程序") {
                        Text(diagnostics.report.memoryStatusText)
                        Text("原生根分頁名額 \(diagnostics.report.nativeBrowserCount)（含關閉中）；不含 AI 登入彈窗；不等於 renderer 程序數")
                            .foregroundStyle(.secondary)
                        Text("RSS MB（ri_phys_footprint）").foregroundStyle(.secondary)
                        Text(diagnostics.report.processStatus).foregroundStyle(.secondary)
                        Text(BrowserProcessHealth.countExplanation).foregroundStyle(.secondary)
                        Text("renderer 終止回呼：\(diagnostics.report.processHealth.terminationCallbackCount)")
                        Grid(alignment: .leading, horizontalSpacing: BrowserSidebarMetrics.laneCardPadding) {
                            GridRow { Text("PID"); Text("角色"); Text("RSS MB"); Text("角色啟動數"); Text("restartCount／最近終止原因") }.bold()
                            ForEach(diagnostics.report.processes) { process in
                                GridRow {
                                    Text("\(process.pid)")
                                    Text(process.role)
                                    Text(BrowserDiagnosticsReport.memory(process.megabytes))
                                    Text(diagnostics.report.processHealth.launchCounts[process.role].map(String.init) ?? "—")
                                    Text("\(BrowserProcessHealth.restartCountText)\n\(diagnostics.report.processHealth.latestReason(for: process.role))")
                                }
                            }
                        }
                        Text("已讀總和 \(BrowserDiagnosticsReport.memory(diagnostics.report.totalMB))；helper \(BrowserDiagnosticsReport.memory(diagnostics.report.helperMB))")
                        Text("最近 \(diagnostics.report.processHealth.recentTerminations.count) 次 renderer 終止（本次 App 執行）").bold()
                        ForEach(diagnostics.report.processHealth.recentTerminations) { event in
                            Text(event.text)
                        }
                    }
                    BrowserDiagnosticsCard(title: "分頁") {
                        Text("總數 \(diagnostics.report.tabs.count)；睡眠 \(diagnostics.report.sleepingCount)")
                        Grid(alignment: .leading, horizontalSpacing: BrowserSidebarMetrics.rowSpacing) {
                            GridRow { Text("owner"); Text("title"); Text("host"); Text("睡眠"); Text("最後活動") }.bold()
                            ForEach(diagnostics.report.tabs) { tab in
                                GridRow {
                                    Text(tab.owner)
                                    Text(tab.title).lineLimit(2)
                                    Text(tab.host).lineLimit(2)
                                    Text(tab.sleeping ? "是" : "否")
                                    Text(tab.lastActive, format: .dateTime.month().day().hour().minute().second())
                                }
                            }
                        }
                    }
                    BrowserDiagnosticsCard(title: "WebMCP") {
                        ForEach(diagnostics.report.tabs) { tab in
                            Text("\(tab.owner) · \(tab.title) · \(tab.host)").bold()
                            Text(tab.tools.isEmpty ? "無工具" : tab.tools.joined(separator: "\n"))
                        }
                        Text("審計 · \(diagnostics.report.audit.status)").bold()
                        ForEach(Array(diagnostics.report.audit.lines.enumerated()), id: \.offset) { _, line in
                            Text(line).font(.system(size: BrowserSidebarMetrics.metaFontSize))
                        }
                    }
                    BrowserDiagnosticsCard(title: "AI 登入紀錄") {
                        Text(diagnostics.report.aiLogins.status)
                        ForEach(Array(diagnostics.report.aiLogins.lines.enumerated()), id: \.offset) { _, line in
                            Text(line).font(.system(size: BrowserSidebarMetrics.metaFontSize))
                        }
                    }
                    BrowserDiagnosticsCard(title: "政策") {
                        if diagnostics.report.policies.isEmpty { Text("尚無安全決定") }
                        ForEach(diagnostics.report.policies) { entry in
                            Text("\(entry.time.formatted(date: .omitted, time: .standard)) | \(entry.host) | \(entry.decision) | \(entry.actor)")
                        }
                    }
                }
            }
        }
        .padding(BrowserSidebarMetrics.laneCardPadding)
        .frame(minWidth: BrowserSidebarMetrics.laneCardWidth, idealWidth: BrowserSidebarMetrics.diagnosticsIdealWidth,
               minHeight: BrowserSidebarMetrics.diagnosticsMinHeight, idealHeight: BrowserSidebarMetrics.diagnosticsIdealHeight)
        .monospacedDigit() // tabular-nums
        .textSelection(.enabled)
        .task { await diagnostics.observe() }
    }

    private func copyReport() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnostics.report.text, forType: .string)
    }
}

private struct BrowserDiagnosticsCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: BrowserSidebarMetrics.rowSpacing) {
            Text(title).font(.headline)
            content.font(.system(size: BrowserSidebarMetrics.rowFontSize))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(BrowserSidebarMetrics.laneCardPadding)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: BrowserSidebarMetrics.laneCardCornerRadius))
    }
}
