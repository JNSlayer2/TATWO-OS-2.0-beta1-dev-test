import SwiftUI
import AppKit

@MainActor
final class FeedbackCoordinator: ObservableObject {
    static let shared = FeedbackCoordinator()
    private static var canvases: [UUID: FeedbackCoordinator] = [:]
    static func forPlan(_ id: UUID) -> FeedbackCoordinator {
        if let coordinator = canvases[id] { return coordinator }
        let coordinator = FeedbackCoordinator(planID: id)
        canvases[id] = coordinator
        return coordinator
    }
    @Published var isPresented = false
    @Published var title = "" { didSet { changed() } }
    @Published var content = "" { didSet { changed() } }
    @Published private(set) var account: String?
    @Published private(set) var source = "Chat"
    @Published private(set) var phase: FeedbackPanel.Phase = .draft
    @Published var manualConfirmation = false
    @Published private(set) var requiresManualConfirmation = false
    @Published private(set) var reviewedBody: String?
    var destination: String {
        guard let draft = service?.draft, draft.deliveryPending || draft.issueNumber != nil else {
            return FeedbackService.repository
        }
        return draft.deliveryRepository ?? FeedbackService.repository
    }
    private let accounts = GitHubAccountsStore()
    private var service: FeedbackService?
    private var loading = false

    init(planID: UUID? = nil) {
        let root = ProcessInfo.processInfo.environment["TATWO2_LIVE_ROOT"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("tatwo2/live", isDirectory: true)
        do {
            let filename = planID.map { $0.uuidString + ".json" } ?? "draft.json"
            service = try FeedbackService(draftURL: root.appendingPathComponent("feedback/\(filename)"),
                                          reviewer: FeedbackNativeReview.review,
                                          http: FeedbackHTTPTransport.shared.perform)
            restore()
        } catch { phase = .failed(FeedbackFailure.persistence.localizedDescription) }
    }

    private func restore() {
        guard let service else { return }
        manualConfirmation = false; requiresManualConfirmation = false
        reviewedBody = service.draft.deliveryPending || service.draft.issueNumber != nil ? service.draft.deliveryBody : nil
        loading = true
        title = service.draft.title; content = service.draft.body
        account = service.draft.account.isEmpty ? nil : service.draft.account
        loading = false
        if let number = service.draft.issueNumber { phase = .submitted(number) }
        else if service.draft.deliveryPending { phase = .unconfirmed }
        else { phase = .draft }
    }

    @discardableResult
    func present(source: String, initialText: String = "") -> Bool {
        self.source = source
        if !phase.isBusy { refreshAccount() }
        // Never overwrite a saved draft or automatically copy a whole chat/note.
        if title.isEmpty && content.isEmpty && phase == .draft && !initialText.isEmpty { content = initialText }
        isPresented = true
        return initialText.isEmpty || content == initialText
    }

    func presentation(for owner: String) -> Binding<Bool> {
        Binding(get: { self.isPresented && self.source == owner },
                set: { if !$0 && self.source == owner { self.close() } })
    }

    func close() { isPresented = false }

    func refreshAccount() {
        guard let service, !service.draft.deliveryPending, service.draft.issueNumber == nil else { return }
        let next = (try? accounts.loadAccounts())?.first?.username
        if next != account { account = next; phase = .draft; changed() }
    }

    private func identity() throws -> FeedbackIdentity {
        let records = try accounts.loadAccounts()
        guard let active = records.first, active.username == account,
              let token = try accounts.mcpToken(username: active.username), !token.isEmpty else { throw FeedbackFailure.login }
        return FeedbackIdentity(username: active.username, token: token)
    }

    private func changed() {
        guard !loading, let service else { return }
        manualConfirmation = false; requiresManualConfirmation = false; reviewedBody = nil
        do {
            try service.update(title: title, body: content, account: account ?? "")
            if phase == .reviewed { phase = .draft }
        } catch { phase = service.draft.deliveryPending ? .unconfirmed : .failed(error.localizedDescription) }
    }

    func edit() {
        guard phase == .reviewed else { return }
        manualConfirmation = false; requiresManualConfirmation = false; reviewedBody = nil
        phase = .draft
    }

    func repositoryChanged() {
        if phase == .reviewed { edit() }
    }

    func review() {
        guard phase.allowsEditing, let service else { return }
        refreshAccount()
        do {
            try service.update(title: title, body: content, account: account ?? "")
            let identity = try identity()
            let model = TatwoChatProcessCompositionRegistry.chatPageModel {
                TatwoAppMCPRuntimeRegistry.state
            }
            let hasEngine = model.engineLogins.contains(where: \.isLoggedIn)
            let engine = model.selectedThread == nil ? "none" : model.routeChoice.engine.rawValue
            let environment = FeedbackEnvironment.current(engine: engine)
            manualConfirmation = false; requiresManualConfirmation = false; reviewedBody = nil
            phase = .checking
            Task {
                do {
                    let manual = try await service.review(identity: identity, hasLoggedInEngine: hasEngine,
                                                          environment: environment)
                    let now = try self.identity()
                    guard now.username == identity.username, now.token == identity.token else { throw FeedbackFailure.changed }
                    requiresManualConfirmation = manual
                    reviewedBody = service.preparedBody
                    phase = .reviewed
                } catch { phase = .blocked(error.localizedDescription) }
            }
        } catch { phase = .blocked(error.localizedDescription) }
    }

    func submit() {
        guard phase == .reviewed, !requiresManualConfirmation || manualConfirmation, let service else { return }
        do {
            let identity = try identity()
            let confirmed = manualConfirmation
            phase = .submitting
            Task {
                do { phase = .submitted(try await service.submit(identity: identity, manualConfirmation: confirmed)) }
                catch { phase = service.draft.deliveryPending ? .unconfirmed : .failed(error.localizedDescription) }
            }
        } catch { phase = .failed(error.localizedDescription) }
    }

    func checkSubmission() {
        guard phase == .unconfirmed, let service else { return }
        do {
            let identity = try identity()
            phase = .submitting
            Task {
                do {
                    if let number = try await service.reconcile(identity: identity) { phase = .submitted(number) }
                    else { phase = .unconfirmed; openIssue() }
                } catch { phase = .unconfirmed; openIssue() }
            }
        } catch { openIssue() } // stays uncertain; never unlock POST merely on a lookup miss.
    }

    func openIssue() {
        let suffix = service?.draft.issueNumber.map { "/\($0)" } ?? ""
        if let url = URL(string: "https://github.com/\(destination)/issues" + suffix) { NSWorkspace.shared.open(url) }
    }

    func newDraft() {
        do { try service?.beginNewDraft(); restore(); refreshAccount() }
        catch { phase = .failed(error.localizedDescription) }
    }
}
