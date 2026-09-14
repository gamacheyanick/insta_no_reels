import Foundation

/// Central place to tweak how the wrapper behaves without hunting through
/// the WebView/JS code.
enum AppConfig {
    /// Which User-Agent instagram.com sees.
    ///
    /// `.mobile` serves Instagram's own mobile web app, which is already
    /// designed for a phone-width screen — no layout hacks needed, and it
    /// still supports posting, DMs, stories, notifications, etc.
    ///
    /// `.desktop` serves the full desktop web app squeezed into the
    /// phone-sized WKWebView. A few desktop-only affordances exist, but the
    /// layout isn't built for a narrow viewport, so some screens look
    /// cramped or need pinch-zoom.
    ///
    /// Start with `.mobile`; switch to `.desktop` only if you find the
    /// mobile web app is missing something you need.
    static let userAgentMode: UserAgentMode = .mobile

    /// Also hide individual Reels-type posts that show up mixed into the
    /// main feed (not just blocking the Reels tab itself). Instagram's
    /// ranking sometimes serves Reels-format videos in the regular feed
    /// even when the Reels tab is untouched.
    static let hideReelsInsideFeed = true

    static let startURL = URL(string: "https://www.instagram.com/")!
}

enum UserAgentMode {
    case mobile
    case desktop

    var userAgentString: String {
        switch self {
        case .mobile:
            return "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"
        case .desktop:
            return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15"
        }
    }
}
