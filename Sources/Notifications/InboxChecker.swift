import Foundation
import UserNotifications

/// Polls Instagram's DM inbox with a captured session and posts a local
/// notification for each new incoming message. Runs from iOS background
/// refresh (roughly hourly, at iOS's discretion) and on a short timer while
/// the app is in the foreground.
@MainActor
final class InboxChecker {
    static let shared = InboxChecker()

    /// True while the user is looking at Messages in the web view, so
    /// foreground checks don't announce what's already on screen.
    var isViewingMessages: () -> Bool = { false }

    private let defaults = UserDefaults.standard
    private let baselineKey = "inboxBaseline"
    private var isChecking = false
    private var foregroundTimer: Timer?

    // MARK: - Scheduling

    func startForegroundPolling(accountID: String) {
        stopForegroundPolling()
        Task { await check(accountID: accountID) }
        foregroundTimer = Timer.scheduledTimer(withTimeInterval: AppConfig.inboxForegroundInterval, repeats: true) { _ in
            Task { @MainActor in
                await InboxChecker.shared.check(accountID: accountID)
            }
        }
    }

    func stopForegroundPolling() {
        foregroundTimer?.invalidate()
        foregroundTimer = nil
    }

    // MARK: - Checking

    func check(accountID: String) async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        guard let cookies = SessionCookieStore.load(accountID: accountID),
              cookies.isLoggedIn,
              let viewerID = cookies.userID,
              let inbox = await fetchInbox(cookies: cookies)
        else { return }

        // Baseline: the newest message timestamp already accounted for, per
        // thread. On the very first check just record the current state so
        // existing messages don't all fire as notifications.
        let existing = loadBaseline(accountID: accountID)
        let isFirstRun = existing == nil
        var baseline = existing ?? [:]
        var fresh: [IncomingMessage] = []

        for thread in inbox.threads {
            guard let item = thread.lastItem else { continue }
            let previous = baseline[thread.id] ?? 0
            baseline[thread.id] = max(previous, item.timestamp)

            guard !isFirstRun,
                  item.senderID != viewerID,
                  item.timestamp > previous,
                  !thread.viewerHasSeen(item, viewerID: viewerID)
            else { continue }
            fresh.append(IncomingMessage(thread: thread, item: item))
        }
        saveBaseline(baseline, accountID: accountID)

        try? await UNUserNotificationCenter.current().setBadgeCount(inbox.unseenCount)

        guard !fresh.isEmpty, !isViewingMessages() else { return }
        for message in fresh {
            await post(message)
        }
    }

    private func post(_ message: IncomingMessage) async {
        let content = UNMutableNotificationContent()
        content.title = message.title
        content.body = message.preview
        content.sound = .default
        content.threadIdentifier = message.thread.id
        content.userInfo = ["threadID": message.thread.id]

        let request = UNNotificationRequest(
            identifier: "dm-\(message.thread.id)-\(message.item.id)",
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Network

    private func fetchInbox(cookies: SessionCookies) async -> InboxSnapshot? {
        var components = URLComponents(string: "https://www.instagram.com/api/v1/direct_v2/inbox/")!
        components.queryItems = [
            URLQueryItem(name: "persistentBadging", value: "true"),
            URLQueryItem(name: "folder", value: ""),
            URLQueryItem(name: "limit", value: "20"),
            URLQueryItem(name: "thread_message_limit", value: "1"),
        ]
        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue(cookies.cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("936619743392459", forHTTPHeaderField: "X-IG-App-ID")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("https://www.instagram.com/direct/inbox/", forHTTPHeaderField: "Referer")
        request.setValue(AppConfig.userAgentMode.userAgentString, forHTTPHeaderField: "User-Agent")
        if let csrf = cookies.csrfToken {
            request.setValue(csrf, forHTTPHeaderField: "X-CSRFToken")
        }

        // Ephemeral session with cookie handling off, so only the captured
        // cookies are sent and nothing gets persisted outside the web view.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        let session = URLSession(configuration: configuration)

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200
        else { return nil }
        return InboxSnapshot(data: data)
    }

    // MARK: - Baseline persistence

    private func loadBaseline(accountID: String) -> [String: Int64]? {
        guard let data = defaults.data(forKey: baselineKey),
              let all = try? JSONDecoder().decode([String: [String: Int64]].self, from: data)
        else { return nil }
        return all[accountID]
    }

    private func saveBaseline(_ baseline: [String: Int64], accountID: String) {
        var all: [String: [String: Int64]] = [:]
        if let data = defaults.data(forKey: baselineKey),
           let decoded = try? JSONDecoder().decode([String: [String: Int64]].self, from: data) {
            all = decoded
        }
        all[accountID] = baseline
        defaults.set(try? JSONEncoder().encode(all), forKey: baselineKey)
    }
}

// MARK: - Inbox model (parsed loosely — Instagram's JSON shifts over time)

struct InboxSnapshot {
    let threads: [InboxThread]
    let unseenCount: Int

    init?(data: Data) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let inbox = root["inbox"] as? [String: Any]
        else { return nil }
        unseenCount = inbox["unseen_count"] as? Int ?? 0
        threads = (inbox["threads"] as? [[String: Any]] ?? []).compactMap(InboxThread.init(json:))
    }
}

struct InboxThread {
    struct User {
        let id: String
        let username: String
    }

    let id: String
    let title: String
    let users: [User]
    let lastItem: InboxItem?
    /// Viewer id → timestamp of the last item they've seen.
    let lastSeen: [String: Int64]

    var isGroup: Bool { users.count > 1 }

    init?(json: [String: Any]) {
        guard let id = JSONValue.string(json["thread_id"]) else { return nil }
        self.id = id
        title = json["thread_title"] as? String ?? ""
        users = (json["users"] as? [[String: Any]] ?? []).compactMap { user in
            guard let username = user["username"] as? String,
                  let id = JSONValue.string(user["pk"]) ?? JSONValue.string(user["pk_id"])
            else { return nil }
            return User(id: id, username: username)
        }
        lastItem = (json["last_permanent_item"] as? [String: Any]).flatMap(InboxItem.init(json:))

        var seen: [String: Int64] = [:]
        for (viewer, value) in json["last_seen_at"] as? [String: [String: Any]] ?? [:] {
            if let timestamp = JSONValue.int64(value["timestamp"]) {
                seen[viewer] = timestamp
            }
        }
        lastSeen = seen
    }

    func viewerHasSeen(_ item: InboxItem, viewerID: String) -> Bool {
        guard let seen = lastSeen[viewerID] else { return false }
        return seen >= item.timestamp
    }

    func username(for userID: String) -> String? {
        users.first { $0.id == userID }?.username
    }
}

struct InboxItem {
    let id: String
    let senderID: String
    let timestamp: Int64
    let type: String
    let text: String?
    let mediaType: Int?
    let linkText: String?

    init?(json: [String: Any]) {
        guard let id = JSONValue.string(json["item_id"]),
              let senderID = JSONValue.string(json["user_id"]),
              let timestamp = JSONValue.int64(json["timestamp"])
        else { return nil }
        self.id = id
        self.senderID = senderID
        self.timestamp = timestamp
        type = json["item_type"] as? String ?? ""
        text = json["text"] as? String
        mediaType = (json["media"] as? [String: Any])?["media_type"] as? Int
        linkText = (json["link"] as? [String: Any])?["text"] as? String
    }
}

struct IncomingMessage {
    let thread: InboxThread
    let item: InboxItem

    var senderName: String {
        thread.username(for: item.senderID) ?? thread.title
    }

    var title: String {
        thread.isGroup && !thread.title.isEmpty ? "@\(senderName) in \(thread.title)" : "@\(senderName)"
    }

    var preview: String {
        switch item.type {
        case "text": return item.text ?? "sent a message"
        case "media": return item.mediaType == 2 ? "sent a video" : "sent a photo"
        case "raven_media": return "sent a disappearing photo"
        case "media_share", "xma_media_share": return "sent a post"
        case "clip", "xma_clip": return "sent a reel"
        case "story_share", "xma_story_share": return "sent a story"
        case "reel_share": return "replied to your story"
        case "voice_media": return "sent a voice message"
        case "animated_media": return "sent a GIF"
        case "like": return "❤️"
        case "link": return item.linkText ?? item.text ?? "sent a link"
        default: return item.text ?? "sent a message"
        }
    }
}

private enum JSONValue {
    static func string(_ value: Any?) -> String? {
        switch value {
        case let string as String: return string
        case let number as NSNumber: return number.stringValue
        default: return nil
        }
    }

    static func int64(_ value: Any?) -> Int64? {
        switch value {
        case let number as NSNumber: return number.int64Value
        case let string as String: return Int64(string)
        default: return nil
        }
    }
}
