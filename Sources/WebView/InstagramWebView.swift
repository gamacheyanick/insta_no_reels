import SwiftUI
import WebKit

/// The bits of web view state the SwiftUI layer cares about.
final class WebViewState: ObservableObject {
    /// Flips to true once the first page has finished (or failed) loading —
    /// that's when the native splash overlay goes away.
    @Published var hasLoadedOnce = false
}

/// SwiftUI wrapper around a WKWebView pointed at instagram.com, with the
/// content-filtering scripts installed and native navigation guarding for
/// /reels and /explore (belt-and-suspenders alongside the JS-level guard in
/// ContentFilterScript, since a hard link tap does a real navigation that
/// the JS history patch alone wouldn't catch).
///
/// One instance per account: the view is keyed on the account id by
/// ContentView, so switching accounts tears this down and builds a fresh
/// web view on that account's own data store.
struct InstagramWebView: UIViewRepresentable {
    @ObservedObject var state: WebViewState
    let account: Account
    let accountStore: AccountStore
    let usage: UsageTracker

    /// Name of the `window.webkit.messageHandlers.*` bridge the injected
    /// script posts to.
    static let messageHandlerName = "instaNoReels"

    func makeCoordinator() -> Coordinator {
        Coordinator(state: state, account: account, accountStore: accountStore, usage: usage)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = account.dataStore
        configuration.userContentController = Self.makeContentController(coordinator: context.coordinator)
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = AppConfig.userAgentMode.userAgentString
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true

        // Native-feel tweaks: no long-press link preview (a dead giveaway
        // that it's a web view), and the overscroll area matches the system
        // theme instead of flashing white in dark mode.
        webView.allowsLinkPreview = false
        webView.underPageBackgroundColor = .systemBackground

        let refreshControl = UIRefreshControl()
        refreshControl.addTarget(
            context.coordinator,
            action: #selector(Coordinator.handleRefresh(_:)),
            for: .valueChanged
        )
        webView.scrollView.refreshControl = refreshControl

        context.coordinator.webView = webView
        webView.load(URLRequest(url: AppConfig.startURL))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        // The content controller holds the handler strongly; break the
        // reference when the account's web view goes away.
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: messageHandlerName)
    }

    private static func makeContentController(coordinator: Coordinator) -> WKUserContentController {
        let controller = WKUserContentController()

        let scripts = [ContentFilterScript.flags, ContentFilterScript.bootstrap, ContentFilterScript.cleanup]
        for source in scripts {
            controller.addUserScript(
                WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true)
            )
        }
        controller.add(coordinator, name: messageHandlerName)
        return controller
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        weak var webView: WKWebView?
        private let state: WebViewState
        private let account: Account
        private let accountStore: AccountStore
        private let usage: UsageTracker

        private let blockedPathPrefixes = ["/reels", "/explore"]
        private let appStoreHosts = ["apps.apple.com", "itunes.apple.com"]

        init(state: WebViewState, account: Account, accountStore: AccountStore, usage: UsageTracker) {
            self.state = state
            self.account = account
            self.accountStore = accountStore
            self.usage = usage
        }

        @objc func handleRefresh(_ sender: UIRefreshControl) {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            webView?.reload()
        }

        // MARK: - Messages from the injected script

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }

            switch type {
            case "switchAccounts":
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                accountStore.isPickerPresented = true
            case "username":
                if let username = body["value"] as? String, !username.isEmpty {
                    accountStore.setUsername(username, for: account.id)
                }
            case "postViewed":
                usage.recordPostViewed()
            default:
                break
            }
        }

        // MARK: - Navigation lifecycle

        private func finishLoad(_ webView: WKWebView) {
            webView.scrollView.refreshControl?.endRefreshing()
            disablePinchZoom(webView)
            if !state.hasLoadedOnce {
                state.hasLoadedOnce = true
            }
        }

        // WebKit re-enables the pinch gesture on every navigation, so this
        // has to be reapplied rather than set once. The injected viewport
        // meta tag handles the same thing at the page level.
        private func disablePinchZoom(_ webView: WKWebView) {
            webView.scrollView.pinchGestureRecognizer?.isEnabled = false
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            disablePinchZoom(webView)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            finishLoad(webView)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            finishLoad(webView)
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            finishLoad(webView)
        }

        // MARK: - Navigation policy

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }

            // instagram:// and itms-apps:// are "open in the real app"
            // hand-offs from the mobile site's banners — swallow them.
            guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
                decisionHandler(.cancel)
                return
            }

            let host = url.host?.lowercased() ?? ""

            if appStoreHosts.contains(where: { host.hasSuffix($0) }) {
                decisionHandler(.cancel)
                return
            }

            if host.hasSuffix("instagram.com") {
                let path = url.path
                let isSearch = path.hasPrefix("/explore/search")
                let isExploreRoot = path == "/explore" || path == "/explore/"
                let isBlocked = !isSearch && blockedPathPrefixes.contains { path == $0 || path.hasPrefix($0 + "/") }

                // On the mobile layout the nav's search icon links to
                // /explore/. Send it to Instagram's search page instead of
                // the recommendation grid.
                if isExploreRoot && AppConfig.userAgentMode == .mobile {
                    decisionHandler(.cancel)
                    let searchURL = URL(string: "https://www.instagram.com" + ContentFilterScript.searchPath)!
                    webView.load(URLRequest(url: searchURL))
                    return
                }

                if isBlocked {
                    decisionHandler(.cancel)
                    webView.evaluateJavaScript("window.location.replace('https://www.instagram.com/');")
                    return
                }
            }

            decisionHandler(.allow)
        }

        // Instagram opens a handful of links (e.g. external "Learn more"
        // pages) via window.open(). There's no second window in this app,
        // so load them in the same webview instead of silently dropping
        // the tap.
        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if navigationAction.targetFrame == nil {
                webView.load(navigationAction.request)
            }
            return nil
        }

        // Instagram's post/story composer asks for camera/mic access via
        // getUserMedia(). Grant it (subject to the usual iOS system
        // permission prompt) so capture actually works.
        func webView(
            _ webView: WKWebView,
            requestMediaCapturePermissionFor origin: WKSecurityOrigin,
            initiatedByFrame frame: WKFrameInfo,
            type: WKMediaCaptureType,
            decisionHandler: @escaping (WKPermissionDecision) -> Void
        ) {
            decisionHandler(.grant)
        }
    }
}
