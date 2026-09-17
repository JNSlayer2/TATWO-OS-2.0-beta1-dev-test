// 照搬自 Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/ChatPage+Collaboration.swift；改動 5 行（原因：移除舊 Core import，改接同名 Facade 假資料）
import SwiftUI
import AppKit
import Foundation
import Combine
import UniformTypeIdentifiers
import Darwin

extension ChatPage {
    @ViewBuilder
    var pendingHandoffChip: some View {
        if model.activePendingHandoff != nil {
            HStack(spacing: 8) {
                Label("pendingHandoff", systemImage: "shippingbox.and.arrow.backward")
                    .font(.caption2.weight(.black))
                    .foregroundStyle(.cyan)
                Text(model.activePendingHandoffSummary)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Text("read only")
                    .font(.system(size: 9, weight: .black, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .frame(height: 20)
                    .background(Color.white.opacity(0.06), in: Capsule())
                Button { model.clearPendingHandoff() } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .help("清除待併入交接包")
            }
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background(Color.cyan.opacity(0.075), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.cyan.opacity(0.20), lineWidth: 1))
            .help("匯入交接包後只顯示摘要；下次送出會併入隱藏 context，送出後自動清除。")
        }
    }

    var skillSuggestionRail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Label("$ skills", systemImage: "dollarsign.circle")
                    .font(.caption2.weight(.black))
                    .foregroundStyle(.secondary)
                ForEach(Array(model.skillSuggestions.enumerated()), id: \.element.id) { idx, entry in
                    let isSelected = model.skillSuggestionSelectedIndex == idx
                    Button {
                        model.applySkillSuggestion(entry)
                    } label: {
                        Text("$\(entry.id)")
                            .font(.caption2.monospaced().weight(.bold))
                            .lineLimit(1)
                            .foregroundStyle(isSelected ? LiquidGlassTokens.brandAccent : .primary)
                            .padding(.horizontal, 8)
                            .frame(height: 24)
                            .background(
                                LiquidGlassTokens.brandAccent.opacity(isSelected ? 0.20 : 0.08),
                                in: Capsule())
                            .overlay(
                                Capsule().strokeBorder(
                                    isSelected ? LiquidGlassTokens.brandAccent : Color.clear,
                                    lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                    .help("→ 選取、Enter 插入，或點擊/右鍵插入 $\(entry.id)：\(entry.trigger)")
                    // 使用者 #63：右鍵可選到對話筐，不用打整段。
                    .contextMenu {
                        Button {
                            model.applySkillSuggestion(entry)
                        } label: {
                            Label("插入 $\(entry.id) 到輸入框", systemImage: "text.insert")
                        }
                        if !entry.trigger.isEmpty {
                            Section("用途") { Text(entry.trigger) }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 30)
        .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
    }


    func collaborationStrengthSlider(level: ChatCollaborationLevel) -> some View {
        let options = ChatCollaborationLevel.allCases.filter { $0 != .off }
        let committedIsActive = level != .off
        let visualLevel = pendingCollaborationLevel ?? level
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("ULTRAWORK")
                        .font(.system(
                            size: 10,
                            weight: .black,
                            design: .rounded))
                        .tracking(1.2)
                        .foregroundStyle(LiquidGlassTokens.brandAccent)
                    Text(committedIsActive
                        ? "\(visualLevel.title) 協作編制"
                        : "單模型模式")
                        .font(.system(size: 13, weight: .bold))
                }
                Spacer(minLength: 8)
                Text(model.isPlanModeEnabled
                    ? "PLAN · 唯讀"
                    : "確認後 · 可執行")
                    .font(.system(
                        size: 9,
                        weight: .black,
                        design: .rounded))
                    .foregroundStyle(
                        model.isPlanModeEnabled
                            ? Color.secondary
                            : LiquidGlassTokens.loopsPositive)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(
                        (model.isPlanModeEnabled
                            ? Color.secondary
                            : LiquidGlassTokens.loopsPositive)
                            .opacity(0.10),
                        in: Capsule())
            }

            HStack(spacing: 5) {
                ForEach(options, id: \.self) { option in
                    Button {
                        withAnimation(.spring(
                            response: 0.22,
                            dampingFraction: 0.86))
                        {
                            model.setCollaborationLevel(option)
                            pendingCollaborationLevel = nil
                            collaborationControlExpanded = true
                            collaborationSliderRevealProgress = 1
                        }
                    } label: {
                        Text(option.title)
                            .font(.system(
                                size: 11,
                                weight: .black,
                                design: .rounded))
                            .frame(maxWidth: .infinity)
                            .frame(height: 28)
                            .foregroundStyle(
                                visualLevel == option
                                    ? Color.white
                                    : Color.primary.opacity(0.72))
                            .background(
                                visualLevel == option
                                    ? LiquidGlassTokens.brandAccent
                                    : Color.white.opacity(0.045),
                                in: RoundedRectangle(
                                    cornerRadius: 8,
                                    style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(
                        "ultrawork-mode-\(option.title.lowercased())")
                    .accessibilityAddTraits(
                        visualLevel == option ? .isSelected : [])
                }
            }

            if committedIsActive {
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text("身份與模型")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("點擊任一列更換")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.tertiary)
                    }
                    loopsTeamRow(level: visualLevel)
                }
            } else {
                Button {
                    withAnimation(.spring(
                        response: 0.22,
                        dampingFraction: 0.86))
                    {
                        model.setCollaborationLevel(.s)
                        collaborationControlExpanded = true
                        collaborationSliderRevealProgress = 1
                    }
                } label: {
                    Label("啟用 Ultrawork S", systemImage: "bolt.fill")
                        .font(.system(size: 11, weight: .bold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 30)
                }
                .buttonStyle(.plain)
                .foregroundStyle(LiquidGlassTokens.brandAccent)
                .background(
                    LiquidGlassTokens.brandAccent.opacity(0.10),
                    in: RoundedRectangle(
                        cornerRadius: 9,
                        style: .continuous))
            }

            HStack(spacing: 7) {
                Image(systemName: model.isPlanModeEnabled
                    ? "lock.fill"
                    : "checkmark.shield.fill")
                    .font(.system(size: 9, weight: .bold))
                Text(model.isPlanModeEnabled
                    ? "Plan 階段不寫檔；確認 Goal 後才投影受控工作目錄。"
                    : "執行權限綁定 Goal、角色與受控輸出根。")
                    .font(.system(size: 9, weight: .medium))
                    .lineLimit(2)
                Spacer(minLength: 0)
                Button {
                    withAnimation(.spring(
                        response: 0.22,
                        dampingFraction: 0.86))
                    {
                        model.setCollaborationLevel(.off)
                        pendingCollaborationLevel = nil
                        collaborationControlExpanded = false
                        collaborationSliderRevealProgress = 0
                    }
                } label: {
                    Image(systemName: "power")
                        .font(.system(size: 9, weight: .black))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help("關閉 Ultrawork 協作；回到單模型 thread。")
            }
            .foregroundStyle(.secondary)
        }
        .padding(8)
        .frame(width: 286)
        .accessibilityLabel("Chat collaboration level")
        .accessibilityValue(visualLevel.title)
    }

    var ultraworkOffActivationPill: some View {
        Button {
            prepareCollaborationSliderReveal()
            withAnimation(.spring(response: 0.24, dampingFraction: 0.82)) {
                collaborationControlExpanded = true
            }
        } label: {
            HStack(spacing: 7) {
                Circle()
                    .fill(Color.secondary.opacity(0.24))
                    .frame(width: 7, height: 7)
                Text("ultrawork")
                    .font(.caption2.weight(.black))
                    .foregroundStyle(.secondary)
                Text("單模型 thread")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .black))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(Color.white.opacity(0.034), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("點開後才展開 S/M/L/XL/XXL 協作強度條；Off 保持日常單模型 chat。")
    }

    func collaborationSliderTrack(
        options: [ChatCollaborationLevel],
        level: ChatCollaborationLevel,
        isActive: Bool,
        selectedRaw: Int
    ) -> some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width)
            let segmentCount = max(options.count, 1)
            let segmentWidth = width / CGFloat(segmentCount)
            let laneInset = segmentWidth / 2
            let laneWidth = max(1, width - segmentWidth)
            let denominator = max(options.count - 1, 1)
            let selectedIndex = min(max(selectedRaw - 1, 0), denominator)
            let committedRatio = CGFloat(selectedIndex) / CGFloat(denominator)
            let visualRatio = min(max(collaborationSliderVisualRatio ?? committedRatio, 0), 1)
            let revealProgress = min(max(collaborationSliderRevealProgress, 0), 1)
            let sliderIsLit = isActive || collaborationSliderEditing || collaborationSliderSettling || pendingCollaborationLevel != nil
            let visualSelectedIndex = min(
                max(Int((visualRatio * CGFloat(denominator)).rounded()), 0),
                denominator)
            let commitRatio: (CGFloat) -> Void = { laneRatio in
                let clampedRatio = min(max(laneRatio, 0), 1)
                let rawPosition = Double(clampedRatio) * Double(denominator)
                let dragStartRatio = collaborationSliderDragStartRatio
                let dragDelta = clampedRatio - (dragStartRatio ?? clampedRatio)
                let releaseDirection = abs(collaborationSliderDragDirection) > 0
                    ? collaborationSliderDragDirection
                    : dragDelta
                let lowerIndex = min(max(Int(floor(rawPosition)), 0), denominator)
                let upperIndex = min(lowerIndex + 1, denominator)
                let nearestIndex = min(max(Int(rawPosition.rounded()), 0), denominator)
                let segmentMidpoint = (CGFloat(lowerIndex) + 0.5) / CGFloat(denominator)
                let midpointHysteresis = min(CGFloat(0.04), CGFloat(5) / laneWidth)
                let minimumDirectionalTravel = min(CGFloat(0.03), CGFloat(3) / laneWidth)
                let hasDirectionalTravel = abs(dragDelta) >= minimumDirectionalTravel
                let targetIndex: Int
                if lowerIndex == upperIndex {
                    targetIndex = lowerIndex
                } else if clampedRatio < segmentMidpoint - midpointHysteresis {
                    targetIndex = lowerIndex
                } else if clampedRatio > segmentMidpoint + midpointHysteresis {
                    targetIndex = upperIndex
                } else if hasDirectionalTravel, releaseDirection < 0 {
                    // Direction only resolves the small midpoint band. Outside
                    // it, position wins, so a near-stop one-pixel move cannot
                    // jump a full collaboration level.
                    targetIndex = lowerIndex
                } else if hasDirectionalTravel, releaseDirection > 0 {
                    targetIndex = upperIndex
                } else {
                    targetIndex = nearestIndex
                }
                let nextRaw = min(
                    max(targetIndex + 1, 1),
                    ChatCollaborationLevel.xxl.rawValue
                )
                collaborationSliderSettleGeneration &+= 1
                let settleGeneration = collaborationSliderSettleGeneration
                guard let next = ChatCollaborationLevel(rawValue: nextRaw) else {
                    pendingCollaborationLevel = nil
                    collaborationSliderVisualRatio = nil
                    collaborationSliderDragStartRatio = nil
                    collaborationSliderDragDirection = 0
                    collaborationSliderEditing = false
                    collaborationSliderSettling = false
                    return
                }
                let snappedRatio = CGFloat(nextRaw - 1) / CGFloat(denominator)
                let settleDistance = abs(snappedRatio - clampedRatio)
                // Apple Music progress-bar feel: the glass tracks the pointer
                // directly, then glides into the selected S/M/L/XL/XXL stop with a
                // damped, short-travel settle. The intent is "rubberized
                // scrubber", not a segmented-control magnet and not a toy
                // bounce. Higher damping keeps the release from overshooting
                // while the response remains slow enough to see it travel from
                // an in-between letter gap.
                let settleResponse = 0.68 + min(0.16, Double(settleDistance) * 0.34)
                let intermediateHold = 0.052
                let settleAnimation = Animation.easeInOut(duration: settleResponse)
                let settleDelay = intermediateHold + settleResponse + 0.34
                var releaseTransaction = Transaction()
                releaseTransaction.animation = nil
                withTransaction(releaseTransaction) {
                    // 團隊資料在放開滑桿的當下就切換；只有滑桿本身保留
                    // 緩動 settle，避免下方角色格落後將近一秒。
                    model.setCollaborationLevel(next)
                    showUltraworkPanel = true
                    collaborationSliderEditing = false
                    collaborationSliderSettling = true
                    collaborationControlExpanded = true
                    collaborationSliderRevealProgress = 1
                    pendingCollaborationLevel = next
                    // Keep the visible knob exactly where the user released or
                    // tapped first. The later snap must travel from this
                    // in-between point; otherwise clicks between S/M/L/XL/XXL feel
                    // like direct letter selection.
                    collaborationSliderVisualRatio = clampedRatio
                    collaborationSliderDragStartRatio = nil
                    collaborationSliderDragDirection = 0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + intermediateHold) {
                    guard collaborationSliderSettleGeneration == settleGeneration,
                          pendingCollaborationLevel == next,
                          collaborationSliderSettling else {
                        return
                    }
                    withAnimation(settleAnimation) {
                        collaborationSliderVisualRatio = snappedRatio
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay) {
                    guard collaborationSliderSettleGeneration == settleGeneration,
                          pendingCollaborationLevel == next,
                          collaborationSliderSettling else {
                        return
                    }
                    var transaction = Transaction()
                    transaction.animation = nil
                    withTransaction(transaction) {
                        showUltraworkPanel = true
                        pendingCollaborationLevel = nil
                        collaborationSliderVisualRatio = nil
                        collaborationSliderDragStartRatio = nil
                        collaborationSliderDragDirection = 0
                        collaborationSliderEditing = false
                        collaborationSliderSettling = false
                    }
                }
            }
            let laneRatioForLocalX: (CGFloat) -> CGFloat = { localX in
                min(max((localX - laneInset) / laneWidth, 0), 1)
            }
            let beginPointer: (CGFloat) -> Void = { startRatio in
                collaborationSliderSettleGeneration &+= 1
                var transaction = Transaction()
                transaction.animation = nil
                withTransaction(transaction) {
                    showUltraworkPanel = true
                    collaborationSliderEditing = true
                    collaborationSliderSettling = false
                    collaborationControlExpanded = true
                    collaborationSliderRevealProgress = 1
                    pendingCollaborationLevel = nil
                    collaborationSliderDragStartRatio = startRatio
                    collaborationSliderDragDirection = 0
                    // A new mouse-down owns a fresh visual start. Never inherit
                    // the previous settle position when deriving first motion.
                    collaborationSliderVisualRatio = startRatio
                }
                collaborationSliderPointerDebugLog("editing-began", ratio: startRatio)
            }
            let updatePointer: (CGFloat) -> Void = { currentRatio in
                if collaborationSliderDragStartRatio == nil {
                    beginPointer(currentRatio)
                }
                let startRatio = collaborationSliderDragStartRatio ?? currentRatio
                let previousRatio = collaborationSliderVisualRatio ?? startRatio
                let directionSampleThreshold = min(CGFloat(0.01), CGFloat(1.5) / laneWidth)
                var transaction = Transaction()
                transaction.animation = nil
                withTransaction(transaction) {
                    let delta = currentRatio - previousRatio
                    if abs(delta) >= directionSampleThreshold {
                        collaborationSliderDragDirection = delta
                    }
                    collaborationSliderVisualRatio = currentRatio
                }
                collaborationSliderPointerDebugLog("value", ratio: currentRatio)
            }

            ZStack(alignment: .leading) {
                // #26：連續紫玻璃軌道底（整條完整玻璃，非只有選中小塊）。
                RoundedRectangle(
                    cornerRadius: LiquidGlassTokens.radiusChip,
                    style: LiquidGlassTokens.shapeStyle)
                    .fill(LiquidGlassTokens.ultraworkGradient)
                    .opacity(revealProgress * (sliderIsLit ? 0.30 : 0.16))
                    .overlay {
                        RoundedRectangle(
                            cornerRadius: LiquidGlassTokens.radiusChip,
                            style: LiquidGlassTokens.shapeStyle)
                            .strokeBorder(LiquidGlassTokens.glassRimGradient, lineWidth: 1)
                    }
                    .frame(width: width, height: geometry.size.height)

                // #24：填充式玻璃滑軌——左錨定，寬度隨等級增長（S→XXL 從左往右越拉越長，非移動小塊）。
                RoundedRectangle(
                    cornerRadius: LiquidGlassTokens.radiusChip,
                    style: LiquidGlassTokens.shapeStyle)
                    .fill(LiquidGlassTokens.ultraworkGradient)
                    .overlay {
                        RoundedRectangle(
                            cornerRadius: LiquidGlassTokens.radiusChip,
                            style: LiquidGlassTokens.shapeStyle)
                            .strokeBorder(LiquidGlassTokens.glassRimGradient, lineWidth: 1)
                    }
                    .frame(width: segmentWidth + visualRatio * laneWidth, height: geometry.size.height)
                    .opacity(
                        revealProgress
                            * (sliderIsLit ? 1 : LiquidGlassTokens.tintOpacity))
                    .shadow(
                        color: LiquidGlassTokens.brandAccent.opacity(
                            collaborationSliderHovering
                                ? LiquidGlassTokens.tintOpacity
                                : LiquidGlassTokens.shadowOpacity),
                        radius: LiquidGlassTokens.shadowRadius,
                        x: LiquidGlassTokens.shadowOffsetX,
                        y: LiquidGlassTokens.shadowOffsetY)

                HStack(spacing: 0) {
                    ForEach(Array(options.enumerated()), id: \.element.id) { entry in
                        // 被玻璃填到的等級（<= 當前）用白/主色，未填到用次要色，強化「越拉越長」填充感。
                        let filled = sliderIsLit && entry.offset <= visualSelectedIndex
                        let isCurrent = sliderIsLit && visualSelectedIndex == entry.offset
                        Text(entry.element.title)
                            .font(.system(size: 8, weight: isCurrent ? .black : (filled ? .heavy : .bold), design: .rounded))
                            .foregroundStyle(filled ? Color.white : Color.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .multilineTextAlignment(.center)
                    }
                }
            }
                .frame(width: width, height: geometry.size.height)
                .contentShape(
                    RoundedRectangle(
                        cornerRadius: LiquidGlassTokens.radiusChip,
                        style: LiquidGlassTokens.shapeStyle))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .animation(
                    collaborationSliderEditing ? nil : .easeInOut,
                    value: visualRatio)
                .overlay(alignment: .leading) {
                    ChatSliderPointerOverlay(
                        onBegan: { localX in
                            beginPointer(laneRatioForLocalX(localX))
                        },
                        onChanged: { localX in
                            updatePointer(laneRatioForLocalX(localX))
                        },
                        onEnded: { localX in
                            let releaseRatio = laneRatioForLocalX(localX)
                            updatePointer(releaseRatio)
                            collaborationSliderPointerDebugLog("editing-ended", ratio: releaseRatio)
                            commitRatio(releaseRatio)
                        },
                        onCancelled: {
                            collaborationSliderSettleGeneration &+= 1
                            var transaction = Transaction()
                            transaction.animation = nil
                            withTransaction(transaction) {
                                pendingCollaborationLevel = nil
                                collaborationSliderVisualRatio = nil
                                collaborationSliderDragStartRatio = nil
                                collaborationSliderDragDirection = 0
                                collaborationSliderEditing = false
                                collaborationSliderSettling = false
                            }
                            collaborationSliderPointerDebugLog("cancelled", ratio: committedRatio)
                        },
                        pendingSettleActive:
                            collaborationSliderSettling || pendingCollaborationLevel != nil
                    )
                    .frame(width: width, height: 34)
                    .accessibilityHidden(true)
                    .allowsHitTesting(true)
                }
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.10)) {
                    collaborationSliderHovering = hovering
                }
            }
            .onAppear {
                guard collaborationSliderRevealProgress < 1 else { return }
                DispatchQueue.main.async {
                    withAnimation(.easeOut(duration: 0.30)) {
                        collaborationSliderRevealProgress = 1
                    }
                }
            }
            .help(isActive ? "點擊字母之間或拖曳切換 S/M/L/XL/XXL；收據 gate 仍負責收尾證據。" : "向右拖曳或點擊字母之間啟動 Ultrawork 協作。")
        }
        .frame(height: 34)
    }

    func collaborationSliderPointerDebugLog(_ event: String, ratio: CGFloat) {
        guard ProcessInfo.processInfo.environment["TATWO_SLIDER_POINTER_DEBUG"] == "1" else { return }
        let line = String(
            format: "%@ source=swiftui-slider event=%@ ratio=%.4f editing=%@ settling=%@\n",
            ISO8601DateFormatter().string(from: Date()),
            event,
            Double(ratio),
            collaborationSliderEditing ? "true" : "false",
            collaborationSliderSettling ? "true" : "false"
        )
        guard let data = line.data(using: .utf8) else { return }
        let url = URL(fileURLWithPath: "/tmp/tatwo-slider-pointer.log")
        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }

    func prepareCollaborationSliderReveal() {
        collaborationSliderSettling = false
        collaborationSliderDragDirection = 0
        collaborationSliderRevealProgress = 0
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.30)) {
                collaborationSliderRevealProgress = 1
            }
        }
    }

    var collaborationRoleModelPickerPanel: some View {
        let selectedID = ultraworkRolePickerTarget.map {
            collaborationRoleModelID(for: $0)
        }
        let brandSections = ChatRouteChoice.brandSections(
            selectedID: selectedID)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(ultraworkRolePickerTarget?.label ?? "模型")
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 8)
                Button {
                    withAnimation(.spring(
                        response: 0.20,
                        dampingFraction: 0.86))
                    {
                        ultraworkRolePickerTarget = nil
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close model picker")
            }
            .padding(.horizontal, 14)
            .frame(height: 34)

            Divider().opacity(0.12).padding(.horizontal, 10)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    ForEach(brandSections) { section in
                        modelPickerBrandHeader(section.brand)
                        ForEach(section.choices) { choice in
                            collaborationRoleModelPickerRow(choice)
                                .padding(.leading, 6)
                        }
                    }
                }
                .padding(.bottom, 3)
            }
            .frame(height: modelPickerRouteListHeight)
        }
        .padding(.vertical, 6)
        .liquidGlassPanelSurface(
            cornerRadius: LiquidGlassTokens.radiusCard)
        .accessibilityIdentifier("ultrawork-role-model-picker")
    }

    func collaborationRoleModelPickerRow(
        _ choice: ChatRouteChoice
    ) -> some View {
        let isSelected = ultraworkRolePickerTarget.map {
            ChatRouteChoice.resolve(
                collaborationRoleModelID(for: $0)).id == choice.id
        } ?? false
        return Button {
            guard let slot = ultraworkRolePickerTarget else { return }
            selectCollaborationRoleModel(choice, for: slot)
        } label: {
            HStack(spacing: 8) {
                Text(choice.title)
                    .font(.system(
                        size: 12,
                        weight: isSelected ? .semibold : .medium))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(LiquidGlassTokens.brandAccent)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 30)
            .contentShape(Rectangle())
            .chatMenuRowHover()
        }
        .buttonStyle(.plain)
    }

    /// 目前這個 session 的 Ultrawork 這一級有幾個輔助角色。
    var planUltraworkAuxiliaryCount: Int {
        UltraworkRoleConfiguration.auxiliaryCount(
            for: model.collaborationLevel)
    }

    func collaborationRoleModelID(
        for slot: UltraworkRoleSlot
    ) -> String {
        switch slot {
        case .primary:
            // 主導模型屬於這一列 thread 的 loopsConfig；app-wide 記憶只是
            // 尚未設定時的預設，不可讓另一個 session 的選擇顯示在這裡。
            if let live = Self.normalizedRoleModelID(
                model.activeLoopsConfig?.primaryModelID)
            {
                return live
            }
            return ultraworkRoleConfiguration.primaryModelID
        case let .auxiliary(index):
            if index == 0,
               let live = Self.normalizedRoleModelID(
                model.activeLoopsConfig?.secondaryModelID)
            {
                return live
            }
            return ultraworkRoleConfiguration.auxiliaryModelID(at: index)
        }
    }

    static func normalizedRoleModelID(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(
            in: .whitespacesAndNewlines),
            !trimmed.isEmpty
        else { return nil }
        return trimmed
    }

    func selectCollaborationRoleModel(
        _ choice: ChatRouteChoice,
        for slot: UltraworkRoleSlot
    ) {
        let modelID = choice.canonicalModelSlug
        switch slot {
        case .primary:
            ultraworkRoleConfiguration.setPrimary(modelID)
            model.setPrimaryModel(modelID)
        case let .auxiliary(index):
            ultraworkRoleConfiguration.setAuxiliary(modelID, at: index)
            if index == 0 {
                model.setSecondaryModel(modelID)
            }
        }
        UltraworkRoleConfigurationStore().save(
            ultraworkRoleConfiguration)
        syncPlanFlowSelectionUltraworkRoles()
        withAnimation(.spring(response: 0.20, dampingFraction: 0.86)) {
            ultraworkRolePickerTarget = nil
            showUltraworkPanel = !planInspectorPresented
        }
    }

    /// 在 Plan 畫布裡改 Ultrawork 角色時，同一份選擇必須馬上落到這一列的
    /// 計劃書；否則「已設定主導」只存在 UI，執行閘門仍讀到未指定。
    func syncPlanFlowSelectionUltraworkRoles() {
        guard var selection = model.planFlowSelectionProjection?.selection,
              selection.collaboration == .multiModel
        else { return }
        let auxiliaryCount = planUltraworkAuxiliaryCount
        selection.primaryModelID = collaborationRoleModelID(for: .primary)
        selection.secondaryModelID = auxiliaryCount > 0
            ? collaborationRoleModelID(for: .auxiliary(0))
            : nil
        selection.auxiliaryModelCount = auxiliaryCount
        model.updatePlanFlowSelection(selection)
    }

    /// app-wide 角色記憶只是「這一列還沒宣告任何拓撲」時的預設種子，永遠
    /// 不是既有 row 的權威。2026-08-27 runtime-63：這裡原本無條件把
    /// `gpt-5.5`/`sonnet-5` 寫進剛簽發 XXL contract 的 row，導致同一秒
    /// `loopsConfigChanged` → goal `cancelled/superseded_before_dispatch`，
    /// 那一輪永遠建立不了實體 attempt。判斷全部下沉到 model 端 fail-closed。
    func applyStoredUltraworkRoleConfigurationToModel() {
        guard model.collaborationIsEnabled else { return }
        model.applyStoredUltraworkRoleDefaults(
            primaryModelID: ultraworkRoleConfiguration.primaryModelID,
            secondaryModelID: UltraworkRoleConfiguration.auxiliaryCount(
                for: model.collaborationLevel) > 0
                ? ultraworkRoleConfiguration.auxiliaryModelID(at: 0)
                : nil)
    }

    func collaborationModelPickerLabel(_ modelID: String) -> String {
        switch TatwoChatRouteProfile.resolve(modelID).canonicalModelSlug {
        case "opus-5":
            return "Opus 5"
        case "grok-build":
            return "Grok 4.6"
        default:
            return modelID
        }
    }

    @ViewBuilder
    func loopsTeamRow(
        level: ChatCollaborationLevel
    ) -> some View {
        let auxiliaryCount =
            UltraworkRoleConfiguration.auxiliaryCount(for: level)
        VStack(alignment: .leading, spacing: 6) {
            loopsTeamMember(
                slot: .primary,
                role: "主導",
                tint: LiquidGlassTokens.brandAccent)
            ForEach(0..<auxiliaryCount, id: \.self) { index in
                loopsTeamMember(
                    slot: .auxiliary(index),
                    role: index == 0 ? "副審" : "sub",
                    tint: index == 0 ? .orange : .secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func loopsTeamMember(
        slot: UltraworkRoleSlot,
        role: String,
        tint: Color
    ) -> some View {
        let modelID = collaborationRoleModelID(for: slot)
        return Button {
            withAnimation(.spring(response: 0.22, dampingFraction: 0.86)) {
                ultraworkRolePickerTarget = slot
                showSingleModelPanel = false
            }
        } label: {
            HStack(spacing: 9) {
                Text(role)
                    .font(.system(size: 10, weight: .black, design: .rounded))
                    .foregroundStyle(tint)
                    .frame(width: 38, alignment: .leading)
                VStack(alignment: .leading, spacing: 1) {
                    Text(collaborationModelPickerLabel(modelID))
                        .font(.system(
                            size: 11,
                            weight: .semibold,
                            design: .rounded))
                        .foregroundStyle(Color.primary.opacity(0.86))
                        .lineLimit(1)
                    Text(modelID)
                        .font(.system(
                            size: 8,
                            weight: .medium,
                            design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .black))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 9)
            .frame(minHeight: 38)
            .frame(maxWidth: .infinity)
            .background(
                Color.white.opacity(0.045),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(tint.opacity(0.20), lineWidth: 1))
            .contentShape(
                RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("設定 Ultrawork \(role)模型")
        .accessibilityIdentifier(
            slot == .primary
                ? "ultrawork-role-primary"
                : "ultrawork-role-\(slot.label)")
    }

    /// 團隊 chip 用短名（使用者慣稱 sol/terra/luna/fable5），比「GPT-5.6 terra」易讀。
    func shortLoopsModelName(_ id: String) -> String {
        switch id {
        case "gpt-5.6-sol": return "sol"
        case "gpt-5.6-terra": return "terra"
        case "gpt-5.6-luna": return "luna"
        case "fable-5": return "fable5"
        case "fable-5.1": return "fable5.1"
        case "sonnet-5": return "sonnet5"
        case "grok-build": return "grok"
        case "gpt-5.4": return "gpt5.4"
        case "gpt-5.5": return "gpt5.5"
        case "minimax-m3": return "minimax"
        case "opus-5": return "opus"
        case "haiku-4-5": return "haiku"
        default:
            let name = TatwoChatRouteProfile.resolve(id).displayName
            return name.isEmpty ? id : name
        }
    }

}
