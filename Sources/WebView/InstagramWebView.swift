import SwiftUI
import WebKit

/// SwiftUI wrapper around a WKWebView pointed at instagram.com, with the
/// content-filtering scripts installed and native navigation guarding for
/// /reels and /explore (belt-and-suspenders alongside the JS-level guard in
/// ContentFilterScript, since a hard link tap does a real navigation that
/// the JS history patch alone wouldn't catch).
struct InstagramWebView: UIViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = Self.makeContentController()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []

        // Default configuration already uses the persistent (disk-backed)
        // WKWebsiteDataStore, so the Instagram login session survives
        // relaunching the app — no extra setup needed.
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = AppConfig.userAgentMode.userAgentString
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true

        context.coordinator.webView = webView
        webView.load(URLRequest(url: AppConfig.startURL))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    private static func makeContentController() -> WKUserContentController {
        let controller = WKUserContentController()

        let scripts = [ContentFilterScript.flags, ContentFilterScript.bootstrap, ContentFilterScript.cleanup]
        for source in scripts {
            controller.addUserScript(
                WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true)
            )
        }
        return controller
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        weak var webView: WKWebView?

        private let blockedPathPrefixes = ["/reels", "/explore"]

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url,
                  let host = url.host, host.hasSuffix("instagram.com")
            else {
                decisionHandler(.allow)
                return
            }

            let path = url.path
            let isBlocked = blockedPathPrefixes.contains { path == $0 || path.hasPrefix($0 + "/") }
            if isBlocked {
                decisionHandler(.cancel)
                webView.evaluateJavaScript("window.location.replace('https://www.instagram.com/');")
                return
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
        @available(iOS 15.0, *)
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
