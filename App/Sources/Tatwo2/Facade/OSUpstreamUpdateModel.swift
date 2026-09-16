import Foundation
import Combine

@MainActor
final class OSUpstreamUpdateModel: ObservableObject {
    static let shared = OSUpstreamUpdateModel()
    @Published private(set) var pending: OSUpstreamRefresh.PendingUpdate?
    @Published private(set) var error: String?
    private let runtimePath: String
    private let bundled: URL?
    private var notifiedID: String?

    init(runtimePath: String = OSUpstream.overridePath, bundled: URL? = OSUpstreamRefresh.bundledURL) {
        self.runtimePath = runtimePath
        self.bundled = bundled
    }

    func reload(notify: Bool = false) {
        do {
            pending = try OSUpstreamRefresh.pendingUpdate(runtimePath: runtimePath, bundled: bundled)
            error = nil
            // Call only once the Island host is mounted; info() otherwise drops the notice.
            if notify, let pending, notifiedID != pending.id, IslandNotice.shared.hostAvailable {
                IslandNotice.shared.info(title: "OS 上游有更新", detail: "到設定 › OS 檢視差異；你的版本已保留。")
                notifiedID = pending.id
            }
        } catch {
            pending = nil
            self.error = "無法讀取 OS 上游，請重新檢查。"
        }
    }

    @discardableResult
    func applyBundled(_ reviewed: OSUpstreamRefresh.PendingUpdate) -> Bool {
        resolve {
            _ = try OSUpstreamRefresh.applyBundledVersion(reviewed, runtimePath: runtimePath, bundled: bundled)
        }
    }

    @discardableResult
    func keepCustom(_ reviewed: OSUpstreamRefresh.PendingUpdate) -> Bool {
        resolve {
            try OSUpstreamRefresh.keepCustomVersion(reviewed, runtimePath: runtimePath, bundled: bundled)
        }
    }

    private func resolve(_ operation: () throws -> Void) -> Bool {
        do {
            try operation()
            reload()
            return error == nil
        } catch {
            reload()
            if case OSUpstreamRefresh.ReviewError.contentChanged = error {
                self.error = "內容已變更，請重新檢視差異。"
            } else {
                self.error = "未能儲存選擇，請重新檢查檔案；既有備份會保留。"
            }
            return false
        }
    }
}
