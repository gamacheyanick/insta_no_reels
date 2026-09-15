import Foundation
import WebKit

/// Snapshot of an account's instagram.com cookies, captured while the app
/// is open. Background inbox checks use it to call Instagram's API through
/// URLSession directly — WebKit's processes are suspended in the
/// background, so the web view's own cookie store can't be relied on then.
struct SessionCookies: Codable {
    /// Cookie name → value.
    var values: [String: String]
    var capturedAt: Date

    var cookieHeader: String {
        values.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
    }

    var csrfToken: String? { values["csrftoken"] }
    var userID: String? { values["ds_user_id"] }
    var isLoggedIn: Bool { values["sessionid"] != nil && userID != nil }
}

enum SessionCookieStore {
    private static let key = "sessionCookies"

    /// Must be called on the main thread (WKHTTPCookieStore requirement).
    static func capture(from store: WKHTTPCookieStore, accountID: String) {
        store.getAllCookies { cookies in
            let relevant = cookies.filter { $0.domain.hasSuffix("instagram.com") }
            guard !relevant.isEmpty else { return }
            var values: [String: String] = [:]
            for cookie in relevant {
                values[cookie.name] = cookie.value
            }
            save(SessionCookies(values: values, capturedAt: Date()), accountID: accountID)
        }
    }

    static func load(accountID: String) -> SessionCookies? {
        loadAll()[accountID]
    }

    static func remove(accountID: String) {
        var all = loadAll()
        all[accountID] = nil
        persist(all)
    }

    private static func save(_ cookies: SessionCookies, accountID: String) {
        var all = loadAll()
        all[accountID] = cookies
        persist(all)
    }

    private static func loadAll() -> [String: SessionCookies] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let all = try? JSONDecoder().decode([String: SessionCookies].self, from: data)
        else { return [:] }
        return all
    }

    private static func persist(_ all: [String: SessionCookies]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(all), forKey: key)
    }
}
