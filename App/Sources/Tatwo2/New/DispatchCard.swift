// 照搬自 App/Sources/Tatwo2/New/OpenBrowsersCard.swift；改為 B3 派工卡（同一張玻璃卡、同一列式排版，不新增型別）。
import SwiftUI

/// 主討論串輸入框上方的派工房間卡；動作接既有 live 子討論串。
struct DispatchCard: View {
    @ObservedObject var model: ChatPageModel
    @State private var diffResult: DispatchGitDiff?
    @State private var showsDiff = false
    @State private var diffRoomID: UUID?
    @State private var busy = false
    @State private var expanded =
        ProcessInfo.processInfo.environment["TATWO_ULTRAWORK_EXPORT_WINDOW_SNAPSHOT"] != nil &&
        ProcessInfo.processInfo.environment["TATWO_ULTRAWORK_EXPORT_DISPATCH_EXPANDED"] == "1"

    var body: some View {
        let rooms = model.dispatchRooms
        let running = rooms.filter(\.isRunning).count
        let attention = rooms.filter(\.needsAttention).count
        HStack(alignment: .top, spacing: 8) {
        DisclosureGroup(isExpanded: $expanded) {
            ScrollView {
                details
            }
            .frame(maxHeight: 240)
        } label: {
            HStack(spacing: 7) {
                if running > 0 {
                    ProgressView().controlSize(.mini)
                        .accessibilityLabel("子討論串工作中")
                }
                Text(running > 0 ? "討論串 · \(running) 工作中" : "討論串 · \(rooms.count)")
                if attention > 0 {
                    Label("\(attention) 待查看", systemImage: "exclamationmark.circle")
                        .foregroundStyle(.orange)
                }
                Spacer(minLength: 0)
            }
            .font(ChatTypography.transcriptMeta)
        }
        Button {
            model.hideDiscussionTray()
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("隱藏討論串列；輸入 /顯示討論串 叫回")
        .accessibilityLabel("隱藏討論串列")
        .accessibilityIdentifier("discussion-tray-hide")
        }
        .padding(10)
        .liquidGlassSurface(cornerRadius: LiquidGlassTokens.radiusCard)
        .onChange(of: running) { count in
            if count == 0 { expanded = false }
        }
        .onChange(of: model.selectedThreadID) { _ in expanded = false }
        .sheet(isPresented: $showsDiff) {
            if let result = diffResult {
                DiffReviewView(diffProvider: { result.parsed },
                               goalLabel: result.truncated ? "已截斷（512KB）" : nil,
                               reviewerLabel: result.stat.isEmpty ? nil : result.stat,
                               onReload: {
                                   guard let id = diffRoomID, !busy else { return }
                                   busy = true
                                   Task {
                                       defer { busy = false }
                                       do { diffResult = try await model.loadDispatchDiff(id) }
                                       catch { model.flashComposerHint(String(describing: error)) }
                                   }
                               })
                    .id(result.id)
                    .disabled(busy)
                    .frame(minWidth: 720, minHeight: 480)
                    .toolbar { Button("關閉") { showsDiff = false } }
            }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(model.dispatchRooms) { room in
                let hasWorktree = !model.isLive || (try? model.dispatchGitContext(room.id)) != nil
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(room.title)
                            .font(ChatTypography.transcriptAssistant)
                            .lineLimit(1)
                        Text(room.engineLabel)
                            .font(ChatTypography.transcriptMeta)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if let device = room.deviceLabel, !device.isEmpty {
                        Label(device, systemImage: "laptopcomputer")
                            .font(ChatTypography.transcriptMeta)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .help("這個房間在「\(device)」上跑")
                    }

                    HStack(spacing: 5) {
                        Circle()
                            .fill(room.needsAttention ? .orange : livenessColor(room.liveness))
                            .frame(width: 7, height: 7)
                        Text(room.statusLabel)
                            .font(ChatTypography.transcriptMeta)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .help(lastOutputLabel(room.lastOutputAt))

                    if room.liveness == .done {
                        Button(model.expandedDispatchReports.contains(room.id) ? "收合" : "看報告") { model.toggleDispatchReport(room.id) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    } else if room.isRunning {
                        Button("停") { model.stopDispatchRoom(room.id) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                    Button("開啟") { model.openDispatchRoom(room.id) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    if hasWorktree {
                        Menu {
                            Button("查看 diff") {
                                busy = true
                                Task {
                                    defer { busy = false }
                                    do {
                                        diffResult = try await model.loadDispatchDiff(room.id)
                                        diffRoomID = room.id
                                        showsDiff = true
                                    } catch { model.flashComposerHint(String(describing: error)) }
                                }
                            }
                            if !room.isRunning {
                                Button("複製合併指令") { model.copyDispatchMergeCommand(room.id) }
                                Button("合併到主分支") {
                                    busy = true
                                    Task {
                                        defer { busy = false }
                                        await model.confirmDispatchMerge(room.id)
                                    }
                                }
                                Button("退回重做") { model.presentDispatchReturn(room.id) }
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .disabled(busy)
                        .help(model.dispatchBranchPath(room.id))
                        .accessibilityLabel("\(room.title) 更多操作")
                    }
                }
                if room.liveness == .done, model.expandedDispatchReports.contains(room.id) {
                    HStack(alignment: .top, spacing: 8) {
                        Text(model.dispatchReportExcerpt(room.id))
                            .fixedSize(horizontal: false, vertical: true)
                            .font(ChatTypography.transcriptMeta)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("開啟討論串") { model.openDispatchRoom(room.id) }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                    }
                    .padding(10)
                    .background(LiquidGlassTokens.tint.opacity(LiquidGlassTokens.chipFillOpacity * 0.6),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                Divider().opacity(0.4)
            }

            HStack(spacing: 8) {
                Spacer(minLength: 8)
                if model.dispatchRooms.contains(where: \.isRunning) {
                    Button("全部停") { model.stopAllDispatchRooms() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                Button("合併報告") { model.mergeDispatchReports() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(!model.dispatchRooms.contains(where: \.reportAvailable))
            }
        }
        .padding(.top, 8)
    }

    private func lastOutputLabel(_ date: Date?) -> String {
        guard let date else { return "—" }
        let now = ChatPageModel.isDispatchExportScene
            ? Date(timeIntervalSinceReferenceDate: 800_000_000)
            : Date()
        let minutes = max(0, Int(now.timeIntervalSince(date) / 60))
        return "\(minutes) 分鐘前"
    }

    private func livenessColor(_ liveness: ThreadLiveness) -> Color {
        switch liveness {
        case .active: .green
        case .idle: .yellow
        case .stalled: .red
        case .done: .secondary.opacity(0.55)
        case .failed: .red
        }
    }
}
