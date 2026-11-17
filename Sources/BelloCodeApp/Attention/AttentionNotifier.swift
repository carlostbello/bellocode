import AppKit
import BelloCore
import Engine
import Observation
import UserNotifications

/// Whether the system lets BelloCode post notifications.
enum NotificationAuthorization: Equatable, Sendable {
    /// Never asked.
    case notDetermined
    case authorized
    /// Delivered quietly to Notification Center only.
    case provisional
    case denied
    /// Not a signed app bundle (`swift run`, tests): the notification center is not available at all.
    case unavailable

    var label: String {
        switch self {
        case .notDetermined: "Not set up yet"
        case .authorized: "Allowed"
        case .provisional: "Delivered quietly"
        case .denied: "Turned off in System Settings"
        case .unavailable: "Unavailable in this build"
        }
    }
}

/// One notification as handed to the system.
struct NotificationContent: Equatable, Sendable {
    var identifier: String
    var title: String
    var subtitle: String
    var body: String
    var threadIdentifier: String
    var category: String
    var playsSound: Bool
    var userInfo: [String: String]
}

/// The system's notification center, behind a seam so tests record instead of posting.
@MainActor
protocol NotificationDelivering: AnyObject {
    func authorization() async -> NotificationAuthorization
    func requestAuthorization() async -> NotificationAuthorization
    func post(_ content: NotificationContent)
    func remove(identifiers: [String])
}

/// What a notification action asks for, routed back by the app.
enum NotificationResponse: Equatable, Sendable {
    case open(sessionID: SessionID)
    case allowOnce(sessionID: SessionID, requestID: PermissionRequestID)
    case deny(sessionID: SessionID, requestID: PermissionRequestID)
}

/// Posts notifications for blockers and completions (`NotificationPolicy`), keeps the Dock badge on blockers, asks
/// for authorization at the first moment it is useful (the first agent run, not launch), and routes notification
/// actions back through the Engine with the request card's safety rules.
///
/// Threading: `@MainActor`. Observes `engine.root.attention` only (a token never wakes it).
@MainActor
@Observable
final class AttentionNotifier {
    static let categoryApprovalInline = "approval-inline"
    static let categoryBlocker = "blocker"
    static let categoryCompletion = "completion"
    static let askedKey = "BelloCodeNotificationAuthorizationAsked"

    @ObservationIgnored let engine: Engine
    @ObservationIgnored let settings: AppSettings
    @ObservationIgnored let delivery: (any NotificationDelivering)?
    /// The thread on screen in the key window when the app is active (nil otherwise).
    @ObservationIgnored var frontmostThread: () -> SessionID? = { nil }
    @ObservationIgnored var appIsActive: () -> Bool = { NSApp.isActive }
    /// Opens a thread (and its request) in a window.
    @ObservationIgnored var onOpen: (SessionID) -> Void = { _ in }
    private(set) var authorization: NotificationAuthorization = .notDetermined
    @ObservationIgnored private(set) var posted: [NotificationContent] = []
    @ObservationIgnored private var policy = NotificationPolicy()
    @ObservationIgnored private var loop: ObservationLoop?
    @ObservationIgnored private var wasRunning = false
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private var pendingContent: [String: Task<Void, Never>] = [:]

    init(engine: Engine, settings: AppSettings, delivery: (any NotificationDelivering)?, defaults: UserDefaults?) {
        self.engine = engine
        self.settings = settings
        self.delivery = delivery
        self.defaults = defaults
        authorization = delivery == nil ? .unavailable : .notDetermined
    }

    isolated deinit { loop?.cancel() }

    func start() {
        Task { await refreshAuthorization() }
        loop = ObservationLoop { [weak self] in self?.attentionChanged() }
    }

    func stop() { loop?.cancel() }

    func refreshAuthorization() async {
        guard let delivery else { return }
        authorization = await delivery.authorization()
    }

    /// Settings ▸ Notifications "Allow Notifications…" (or the first agent run).
    @discardableResult
    func requestAuthorization() async -> NotificationAuthorization {
        guard let delivery else { return .unavailable }
        defaults?.set(true, forKey: Self.askedKey)
        authorization = await delivery.requestAuthorization()
        return authorization
    }

    private func attentionChanged() {
        let root = engine.root
        let summary = root.attention
        // The first run of an agent is when notifications start to matter: ask then, once.
        let running = summary.counts.running > 0
        if running, !wasRunning, authorization == .notDetermined, defaults?.bool(forKey: Self.askedKey) != true,
            settings.notifications.mode != .none
        {
            Task { await requestAuthorization() }
        }
        wasRunning = running
        updateDockBadge(summary.counts.dockBadge)
        let directories = Dictionary(root.projects.compactMap { item in item.projectID.map { ($0, item.directory) } }, uniquingKeysWith: { a, _ in a })
        let context = NotificationPolicy.Context(
            appIsActive: appIsActive(), frontmostThread: appIsActive() ? frontmostThread() : nil, settings: settings.notifications,
            projectDirectory: { directories[$0] })
        let requests = policy.evaluate(summary, context: context)
        // Notifications that no longer apply (answered, viewed) leave Notification Center.
        let current = Set(summary.items.map(NotificationPolicy.identifier(for:)))
        let stale = posted.map(\.identifier).filter { !current.contains($0) && !$0.hasPrefix("summary|") }
        if !stale.isEmpty {
            delivery?.remove(identifiers: stale)
            posted.removeAll { stale.contains($0.identifier) }
        }
        for request in requests { post(request) }
    }

    private func updateDockBadge(_ count: Int) {
        guard NSApp != nil else { return }
        let label = count > 0 ? "\(count)" : nil
        if NSApp.dockTile.badgeLabel != label { NSApp.dockTile.badgeLabel = label }
    }

    /// Builds the content off the request (permission details need the engine's pending list) and posts it.
    private func post(_ request: NotificationRequest) {
        guard authorization != .denied, authorization != .unavailable else { return }
        let engine = self.engine
        let projects = engine.root.projects
        let project = projects.first { $0.projectID == request.projectID }
        let thread = projects.lazy.compactMap { [engine] in $0.projectID.flatMap(engine.root.project)?.row(request.sessionID) }.first
        let title = request.kind == .summary ? "\(request.count) threads need you" : (thread?.session.displayTitle ?? "Thread")
        pendingContent[request.identifier]?.cancel()
        pendingContent[request.identifier] = Task { [weak self] in
            var body: String
            var category = request.kind == .completion ? Self.categoryCompletion : Self.categoryBlocker
            var info = ["session": request.sessionID.rawValue, "kind": request.kind.rawValue]
            switch request.kind {
            case .approval:
                let pending = await engine.pendingRequests(for: request.sessionID)
                if case .permission(let permission) = pending.first(where: \.isPermission) {
                    let description = NotificationActionSafety.describe(permission)
                    body = "Needs approval — \(description.text)"
                    info["request"] = permission.id.rawValue
                    if description.allowsInlineApproval { category = Self.categoryApprovalInline }
                } else {
                    body = "Needs approval"
                }
            case .question: body = "Has a question for you"
            case .failure: body = "The last turn failed"
            case .completion: body = "Finished"
            case .summary: body = "Approvals, questions or failures are waiting."
            }
            guard let self, !Task.isCancelled else { return }
            self.pendingContent[request.identifier] = nil
            let content = NotificationContent(
                identifier: request.identifier, title: title, subtitle: project?.name ?? "", body: body,
                threadIdentifier: request.projectID.rawValue, category: category,
                playsSound: self.settings.notifications.playsSound && request.kind != .completion, userInfo: info)
            self.posted.append(content)
            if self.posted.count > 200 { self.posted.removeFirst(self.posted.count - 200) }
            self.delivery?.post(content)
        }
    }

    /// Waits until content for posted requests has been built (tests).
    func settle() async {
        for task in pendingContent.values { await task.value }
    }

    // MARK: - Responses

    /// Parses a notification action into a response.
    static func response(action: String, userInfo: [AnyHashable: Any]) -> NotificationResponse? {
        guard let raw = userInfo["session"] as? String else { return nil }
        let session = SessionID(raw)
        let request: PermissionRequestID? = (userInfo["request"] as? String).map { PermissionRequestID($0) }
        switch action {
        case "allowOnce": return request.map { .allowOnce(sessionID: session, requestID: $0) }
        case "deny": return request.map { .deny(sessionID: session, requestID: $0) }
        default: return .open(sessionID: session)
        }
    }

    /// Acts on a notification action. Allow and Deny apply only to the same request, still pending; Allow is "once"
    /// (never "always" from a notification). Anything else, or a request that changed, opens the thread instead.
    func handle(_ response: NotificationResponse) async {
        switch response {
        case .open(let session):
            onOpen(session)
        case .allowOnce(let session, let requestID), .deny(let session, let requestID):
            let pending = await engine.pendingRequests(for: session)
            guard pending.contains(where: { $0.id == requestID.rawValue }) else {
                onOpen(session)
                return
            }
            let reply: PermissionReply = if case .allowOnce = response { .once } else { .reject }
            do {
                try await engine.reply(to: requestID, reply)
            } catch {
                onOpen(session)
            }
        }
    }
}

/// The real notification center (only inside the .app bundle).
@MainActor
final class SystemNotificationDelivery: NSObject, NotificationDelivering, UNUserNotificationCenterDelegate {
    private let center: UNUserNotificationCenter
    var onResponse: ((NotificationResponse) -> Void)?

    /// nil outside an app bundle (the center would crash without one).
    static func makeIfAvailable() -> SystemNotificationDelivery? {
        guard Bundle.main.bundleIdentifier != nil, Bundle.main.bundleURL.pathExtension == "app" else { return nil }
        return SystemNotificationDelivery()
    }

    private override init() {
        center = UNUserNotificationCenter.current()
        super.init()
        center.delegate = self
        let allow = UNNotificationAction(identifier: "allowOnce", title: "Allow Once", options: [.authenticationRequired])
        let deny = UNNotificationAction(identifier: "deny", title: "Deny", options: [.destructive])
        let open = UNNotificationAction(identifier: "open", title: "Open", options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: AttentionNotifier.categoryApprovalInline, actions: [allow, deny, open], intentIdentifiers: []),
            UNNotificationCategory(identifier: AttentionNotifier.categoryBlocker, actions: [open], intentIdentifiers: []),
            UNNotificationCategory(identifier: AttentionNotifier.categoryCompletion, actions: [open], intentIdentifiers: []),
        ])
    }

    func authorization() async -> NotificationAuthorization {
        let settings = await center.notificationSettings()
        return switch settings.authorizationStatus {
        case .authorized, .ephemeral: .authorized
        case .provisional: .provisional
        case .denied: .denied
        case .notDetermined: .notDetermined
        @unknown default: .notDetermined
        }
    }

    func requestAuthorization() async -> NotificationAuthorization {
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        return await authorization()
    }

    func post(_ content: NotificationContent) {
        let notification = UNMutableNotificationContent()
        notification.title = content.title
        notification.subtitle = content.subtitle
        notification.body = content.body
        notification.threadIdentifier = content.threadIdentifier
        notification.categoryIdentifier = content.category
        notification.sound = content.playsSound ? .default : nil
        notification.userInfo = content.userInfo
        center.add(UNNotificationRequest(identifier: content.identifier, content: notification, trigger: nil))
    }

    func remove(identifiers: [String]) {
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let action = response.actionIdentifier
        let info = response.notification.request.content.userInfo
        // Only strings cross to the main actor.
        let strings = info.reduce(into: [String: String]()) { result, pair in
            if let key = pair.key as? String, let value = pair.value as? String { result[key] = value }
        }
        await MainActor.run {
            guard let parsed = AttentionNotifier.response(action: action, userInfo: strings) else { return }
            self.onResponse?(parsed)
        }
    }
}
