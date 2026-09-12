import SwiftUI

/// A small adapter for the existing device controller; no second session store
/// or background discovery loop. Consent remains bound to the displayed thread.
struct IPadChatConnectionView: View {
    let threadID: UUID?
    let close: () -> Void
    let openSettings: () -> Void
    @ObservedObject private var controller = IPadUseController.shared
    @State private var selectedDeviceID: String?
    @State private var consent: IPadChatConnectionPanel.Phase?
    @State private var localError: String?

    private var phase: IPadChatConnectionPanel.Phase {
        let status = controller.status(caller: threadID ?? UUID())
        if status["deviceStopPending"] as? Bool == true { return .stopping }
        if controller.stopUnconfirmed { return .stopUnconfirmed }
        if controller.busy { return .connecting }
        if controller.authorized {
            return status["authorizedForCaller"] as? Bool == true
                ? .authorizedHere : .ownedElsewhere
        }
        if let consent { return consent }
        if let localError { return .failed(localError) }
        return .choose
    }

    var body: some View {
        IPadChatConnectionPanel(
            devices: controller.devices.map {
                .init(id: $0.id, name: $0.name)
            },
            selectedDeviceID: $selectedDeviceID,
            threadID: threadID,
            activeDeviceName: controller.activeDeviceName,
            phase: phase,
            close: close,
            refresh: { Task { await discover() } },
            openSettings: openSettings,
            requestConsent: { id, owner in
                guard owner == threadID,
                      let device = controller.devices.first(where: { $0.id == id }),
                      !controller.busy, !controller.authorized,
                      !controller.stopUnconfirmed else { return }
                localError = nil
                consent = .consent(
                    device: .init(id: device.id, name: device.name), threadID: owner)
            },
            confirmConsent: { id, owner in
                guard owner == threadID,
                      case let .consent(shownDevice, shownOwner) = consent,
                      shownDevice.id == id, shownOwner == owner,
                      let device = controller.devices.first(where: { $0.id == id }),
                      !controller.busy, !controller.authorized,
                      !controller.stopUnconfirmed else { return }
                consent = nil
                Task {
                    // Authorization belongs to the explicitly confirmed owner,
                    // never whichever thread is selected after this await.
                    await controller.setupAndAuthorize(device, threadID: owner)
                    if controller.status(caller: owner)["authorizedForCaller"] as? Bool != true {
                        localError = controller.state
                    }
                }
            },
            cancelConsent: { consent = nil },
            stop: {
                consent = nil
                localError = nil
                controller.stop()
            }
        )
        .task { await discover() }
        .onChange(of: threadID) { _, _ in consent = nil; localError = nil }
        .onChange(of: controller.devices) { _, devices in
            if !devices.contains(where: { $0.id == selectedDeviceID }) {
                selectedDeviceID = devices.count == 1 ? devices.first?.id : nil
                consent = nil
            }
        }
        .accessibilityIdentifier("ipad-chat-connection")
    }

    private func discover() async {
        if controller.connected {
            selectedDeviceID = controller.activeDeviceID
            return
        }
        guard !controller.connected, !controller.busy,
              !controller.stopUnconfirmed else { return }
        localError = nil
        consent = nil
        await controller.discover()
        if controller.devices.count == 1 {
            selectedDeviceID = controller.devices.first?.id
        }
        if controller.devices.isEmpty { localError = controller.state }
    }
}
