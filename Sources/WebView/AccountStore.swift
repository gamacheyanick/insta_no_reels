import Foundation
import WebKit

/// One Instagram login. Each account gets its own isolated cookie/storage
/// container, so switching is just pointing the web view at a different
/// `WKWebsiteDataStore`.
struct Account: Identifiable, Codable, Equatable {
    /// `nil` means the app's original default data store — that's where
    /// the login from before account switching existed lives, so it's
    /// kept as-is rather than migrated.
    let storeID: UUID?

    /// Detected from the page once logged in; nil until then.
    var username: String?

    var id: String { storeID?.uuidString ?? "default" }

    var dataStore: WKWebsiteDataStore {
        if let storeID {
            return WKWebsiteDataStore(forIdentifier: storeID)
        }
        return .default()
    }
}

final class AccountStore: ObservableObject {
    @Published private(set) var accounts: [Account]
    @Published private(set) var currentID: String
    @Published var isPickerPresented = false

    private let defaults = UserDefaults.standard
    private let accountsKey = "accounts"
    private let currentKey = "currentAccountID"

    init() {
        let defaults = UserDefaults.standard
        let loaded: [Account]
        if let data = defaults.data(forKey: "accounts"),
           let saved = try? JSONDecoder().decode([Account].self, from: data),
           !saved.isEmpty {
            loaded = saved
        } else {
            loaded = [Account(storeID: nil, username: nil)]
        }

        let savedCurrent = defaults.string(forKey: "currentAccountID")
        let initialCurrent: String
        if let savedCurrent, loaded.contains(where: { $0.id == savedCurrent }) {
            initialCurrent = savedCurrent
        } else {
            initialCurrent = loaded[0].id
        }

        accounts = loaded
        currentID = initialCurrent
    }

    var current: Account {
        accounts.first { $0.id == currentID } ?? accounts[0]
    }

    /// The current account id as last saved — readable without an
    /// instance, for background work that runs outside the UI.
    static var persistedCurrentID: String {
        UserDefaults.standard.string(forKey: "currentAccountID") ?? "default"
    }

    func displayName(for account: Account) -> String {
        if let username = account.username {
            return "@\(username)"
        }
        let index = accounts.firstIndex(of: account) ?? 0
        return "Account \(index + 1)"
    }

    func switchTo(_ account: Account) {
        currentID = account.id
        save()
    }

    /// A fresh, empty data store — the web view lands on Instagram's login
    /// page for it.
    func addAccount() {
        let account = Account(storeID: UUID(), username: nil)
        accounts.append(account)
        currentID = account.id
        save()
    }

    func removeCurrent() {
        guard accounts.count > 1 else { return }
        let removed = current
        accounts.removeAll { $0.id == removed.id }
        currentID = accounts[0].id
        save()

        SessionCookieStore.remove(accountID: removed.id)
        if let storeID = removed.storeID {
            WKWebsiteDataStore.remove(forIdentifier: storeID) { _ in }
        }
    }

    func setUsername(_ username: String, for accountID: String) {
        guard let index = accounts.firstIndex(where: { $0.id == accountID }),
              accounts[index].username != username
        else { return }
        accounts[index].username = username
        save()
    }

    private func save() {
        defaults.set(try? JSONEncoder().encode(accounts), forKey: accountsKey)
        defaults.set(currentID, forKey: currentKey)
    }
}
