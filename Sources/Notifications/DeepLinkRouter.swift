import Foundation

/// A URL the web view should navigate to next — set when a notification is
/// tapped, consumed by the web view on its next update.
final class DeepLinkRouter: ObservableObject {
    @Published var pendingURL: URL?
}
