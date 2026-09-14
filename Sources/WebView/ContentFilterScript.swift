import Foundation

/// JavaScript injected into instagram.com to strip Reels, ads, suggested
/// posts, and the Explore page, and to restrict search to accounts only.
///
/// Instagram's markup uses obfuscated, frequently-changing CSS class names,
/// so everything here deliberately keys off stable signals instead:
/// `href` paths (`/reels/`, `/explore/`), `aria-label`s (used for
/// accessibility, so Instagram is unlikely to remove them), and visible
/// text ("Sponsored", "Suggested for you"). When Instagram changes its
/// layout, these are the selectors most likely to still need small tweaks
/// — see the README for how to find and fix them.
enum ContentFilterScript {
    /// Runtime flags read from `AppConfig`, exposed to the JS side. Must be
    /// injected before `bootstrap`/`cleanup`.
    static var flags: String {
        """
        window.__instaNoReelsFlags = { hideReelsInsideFeed: \(AppConfig.hideReelsInsideFeed) };
        """
    }

    /// Runs at document-start, before Instagram's own JS bundle. Patches
    /// `fetch`/`XMLHttpRequest` (to filter search results) and `history`
    /// pushState/replaceState (to block in-app SPA navigation to
    /// /reels and /explore, which a native WKNavigationDelegate can't see
    /// because it never leaves the page).
    static let bootstrap = #"""
    (function () {
      'use strict';

      var blockedPrefixes = ['/reels', '/explore'];

      function isBlockedPath(path) {
        return blockedPrefixes.some(function (p) {
          return path === p || path.indexOf(p + '/') === 0;
        });
      }

      function guardHistoryMethod(name) {
        var original = history[name];
        history[name] = function (state, title, url) {
          try {
            if (url) {
              var resolved = new URL(url, location.href).pathname;
              if (isBlockedPath(resolved)) {
                return; // swallow the navigation, stay on the current page
              }
            }
          } catch (e) {
            /* not a URL we can parse — let it through */
          }
          return original.apply(this, arguments);
        };
      }
      guardHistoryMethod('pushState');
      guardHistoryMethod('replaceState');

      window.addEventListener('popstate', function () {
        if (isBlockedPath(location.pathname)) {
          history.back();
        }
      });

      // ---- Restrict search to accounts only --------------------------
      // Instagram's search box calls internal JSON endpoints and renders
      // whatever comes back. We can't change the server response, so we
      // filter the JSON client-side before Instagram's own code reads it.
      // NOTE: exact field names below are best-effort and may need
      // adjusting if Instagram changes its API shape — see README.
      function isSearchURL(url) {
        return /\/(web\/search\/topsearch|api\/graphql)/.test(String(url || ''));
      }

      function keepAccountsOnly(json) {
        try {
          if (json && Array.isArray(json.users)) {
            json.hashtags = [];
            json.places = [];
          }
          if (json && Array.isArray(json.results)) {
            json.results = json.results.filter(function (r) {
              return r && (r.type === 'user' || r.user);
            });
          }
        } catch (e) {}
        return json;
      }

      var originalFetch = window.fetch;
      window.fetch = function (input, init) {
        var url = typeof input === 'string' ? input : (input && input.url) || '';
        return originalFetch.apply(this, arguments).then(function (response) {
          if (!isSearchURL(url)) return response;
          return response
            .clone()
            .json()
            .then(function (json) {
              var filtered = keepAccountsOnly(json);
              return new Response(JSON.stringify(filtered), {
                status: response.status,
                statusText: response.statusText,
                headers: response.headers
              });
            })
            .catch(function () {
              return response; // not JSON, or shape we don't understand — pass through
            });
        });
      };

      var OriginalXHR = window.XMLHttpRequest;
      function PatchedXHR() {
        var xhr = new OriginalXHR();
        var requestUrl = '';
        var originalOpen = xhr.open;
        xhr.open = function (method, url) {
          requestUrl = url;
          return originalOpen.apply(xhr, arguments);
        };
        xhr.addEventListener('readystatechange', function () {
          if (xhr.readyState !== 4 || !isSearchURL(requestUrl)) return;
          try {
            var filtered = JSON.stringify(keepAccountsOnly(JSON.parse(xhr.responseText)));
            Object.defineProperty(xhr, 'responseText', { value: filtered, configurable: true });
            Object.defineProperty(xhr, 'response', { value: filtered, configurable: true });
          } catch (e) {}
        });
        return xhr;
      }
      window.XMLHttpRequest = PatchedXHR;
    })();
    """#

    /// Runs after the DOM exists. Hides nav icons and sweeps newly-rendered
    /// posts for ads/suggested content via a MutationObserver, since
    /// Instagram is a client-rendered single-page app that keeps injecting
    /// new DOM as you scroll.
    static let cleanup = #"""
    (function () {
      'use strict';

      var flags = window.__instaNoReelsFlags || { hideReelsInsideFeed: true };

      var hideCSS = [
        'a[href="/reels/"], a[href^="/reels/?"],',
        'a[href="/explore/"], a[href^="/explore/?"],',
        '[aria-label="Reels"], [aria-label="Explore"] {',
        '  display: none !important;',
        '}'
      ].join('\n');

      function injectStyle() {
        var style = document.createElement('style');
        style.setAttribute('data-insta-no-reels', 'true');
        style.textContent = hideCSS;
        document.documentElement.appendChild(style);
      }

      function textOf(el) {
        return ((el && (el.innerText || el.textContent)) || '').trim();
      }

      function hide(el) {
        if (el && el.style) el.style.setProperty('display', 'none', 'important');
      }

      function ancestor(el, hops) {
        var node = el;
        for (var i = 0; i < hops && node && node.parentElement; i++) {
          node = node.parentElement;
        }
        return node || el;
      }

      var SUGGESTED_LABELS = ['Suggested for you', 'Suggested Posts', 'Suggested Reels'];

      function sweepArticles() {
        var articles = document.querySelectorAll('article:not([data-insta-no-reels-checked])');
        articles.forEach(function (article) {
          var header = article.querySelector('header') || article;
          var headerText = textOf(header);

          var isSponsored = /\bSponsored\b/.test(headerText);
          var isSuggested = SUGGESTED_LABELS.some(function (label) {
            return headerText.indexOf(label) !== -1;
          });
          var isReel = flags.hideReelsInsideFeed && article.querySelector('a[href^="/reel/"]') !== null;

          if (isSponsored || isSuggested || isReel) {
            hide(article);
          }
          article.setAttribute('data-insta-no-reels-checked', 'true');
        });
      }

      function sweepSuggestedHeadings() {
        var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
        var node;
        while ((node = walker.nextNode())) {
          var text = (node.textContent || '').trim();
          if (SUGGESTED_LABELS.indexOf(text) !== -1) {
            hide(ancestor(node.parentElement, 5));
          }
        }
      }

      function sweepNavIcons() {
        var selector = 'a[href="/reels/"], a[href^="/reels/?"], a[href="/explore/"], a[href^="/explore/?"], [aria-label="Reels"], [aria-label="Explore"]';
        document.querySelectorAll(selector).forEach(function (el) {
          hide(ancestor(el, 2));
        });
      }

      var sweepQueued = false;
      function scheduleSweep() {
        if (sweepQueued) return;
        sweepQueued = true;
        requestAnimationFrame(function () {
          sweepArticles();
          sweepSuggestedHeadings();
          sweepNavIcons();
          sweepQueued = false;
        });
      }

      function start() {
        injectStyle();
        scheduleSweep();
        new MutationObserver(scheduleSweep).observe(document.body, {
          childList: true,
          subtree: true
        });
      }

      if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', start);
      } else {
        start();
      }
    })();
    """#
}
