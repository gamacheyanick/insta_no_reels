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
        window.__instaNoReelsFlags = {
          hideReelsInsideFeed: \(AppConfig.hideReelsInsideFeed),
          autoSkipStoryAds: \(AppConfig.autoSkipStoryAds),
          homePath: "\(AppConfig.homePath)",
          layout: "\(AppConfig.userAgentMode == .mobile ? "mobile" : "desktop")"
        };
        """
    }

    /// Path that the mobile site's search tab is redirected to. On the
    /// mobile layout the nav's magnifying glass is literally the Explore
    /// link, so instead of hiding it we point it at Instagram's own search
    /// page, which is the one /explore/* route we let through.
    static let searchPath = "/explore/search/"

    /// Runs at document-start, before Instagram's own JS bundle. Patches
    /// `fetch`/`XMLHttpRequest` (to filter search results) and `history`
    /// pushState/replaceState (to block in-app SPA navigation to
    /// /reels and /explore, which a native WKNavigationDelegate can't see
    /// because it never leaves the page).
    static let bootstrap = #"""
    (function () {
      'use strict';

      var flags = window.__instaNoReelsFlags || {};
      var SEARCH_PATH = '/explore/search/';

      function isSearchPath(path) {
        return path.indexOf('/explore/search') === 0;
      }

      function isExploreRoot(path) {
        return path === '/explore' || path === '/explore/';
      }

      // /reels/* and /explore/* are blocked, except Instagram's own search
      // page under /explore/search/. On the mobile layout /explore/ itself
      // is where the nav's search icon goes, so it's rerouted to the
      // search page rather than swallowed.
      function isBlockedPath(path) {
        if (isSearchPath(path)) return false;
        return ['/reels', '/explore'].some(function (p) {
          return path === p || path.indexOf(p + '/') === 0;
        });
      }

      function guardHistoryMethod(name) {
        var original = history[name];
        history[name] = function (state, title, url) {
          var args = Array.prototype.slice.call(arguments);
          try {
            if (url) {
              var resolved = new URL(url, location.href);
              var path = resolved.pathname;
              if (path === '/' && !resolved.searchParams.has('variant')) {
                // Ranked home feed is never shown — always the Following feed.
                args[2] = flags.homePath || '/?variant=following';
              } else if (flags.layout === 'mobile' && isExploreRoot(path)) {
                args[2] = SEARCH_PATH;
              } else if (isBlockedPath(path)) {
                return; // swallow the navigation, stay on the current page
              }
            }
          } catch (e) {
            /* not a URL we can parse — let it through */
          }
          return original.apply(this, args);
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

      var flags = window.__instaNoReelsFlags || { hideReelsInsideFeed: true, layout: 'mobile' };
      var SEARCH_PATH = '/explore/search/';

      // On the mobile layout the Explore link *is* the search tab, so it's
      // rerouted (see sweepNavIcons) rather than hidden. Desktop has a
      // separate search flyout, so there Explore can go entirely.
      var exploreSelectors = flags.layout === 'desktop'
        ? ', a[href="/explore/"], a[href^="/explore/?"], [aria-label="Explore"]'
        : '';

      var hideCSS = [
        'a[href="/reels/"], a[href^="/reels/?"], [aria-label="Reels"]' + exploreSelectors + ' {',
        '  display: none !important;',
        '}',
        // Native-feel: no text-selection handles, no long-press callout
        // sheet, no grey tap flash. Inputs keep selection so typing and
        // cursor placement still work in DMs/comments.
        'html, body {',
        '  -webkit-touch-callout: none !important;',
        '  -webkit-user-select: none !important;',
        '  -webkit-tap-highlight-color: transparent !important;',
        '}',
        'input, textarea, [contenteditable=""], [contenteditable="true"] {',
        '  -webkit-user-select: text !important;',
        '  -webkit-touch-callout: default !important;',
        '}'
      ].join('\n');

      function injectStyle() {
        var style = document.createElement('style');
        style.setAttribute('data-insta-no-reels', 'true');
        style.textContent = hideCSS;
        document.documentElement.appendChild(style);
      }

      // Lock the page zoom. The native side also disables the pinch
      // gesture; this covers double-tap-to-zoom and keeps the layout
      // viewport stable.
      var VIEWPORT = 'width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no';
      function applyViewport() {
        var meta = document.querySelector('meta[name="viewport"]');
        if (!meta) {
          meta = document.createElement('meta');
          meta.setAttribute('name', 'viewport');
          (document.head || document.documentElement).appendChild(meta);
        }
        if (meta.getAttribute('content') !== VIEWPORT) {
          meta.setAttribute('content', VIEWPORT);
        }
      }

      // The mobile site nags you to switch to the real app in a few
      // places (top banner, footer bar, "Open app" buttons). Match on the
      // label text and on App Store / instagram:// links.
      var APP_BANNER_LABELS = [
        'Open app', 'Open App', 'Open in app', 'Open Instagram',
        'Use the app', 'Use the App', 'Use app',
        'Get app', 'Get App', 'Get the app', 'Get the App',
        'Download app', 'Download the app', 'Install app',
        'Switch to the app'
      ];
      var APP_STORE_HREF = /apps\.apple\.com|itunes\.apple\.com|itms-apps:|instagram:\/\/|play\.google\.com/i;

      // Climb out of wrappers that contain nothing but this element, so
      // the banner's container goes too rather than leaving an empty bar.
      function tightWrapper(el) {
        var node = el;
        var text = (el.textContent || '').trim();
        for (var i = 0; i < 3; i++) {
          var parent = node.parentElement;
          if (!parent || parent === document.body) break;
          if ((parent.textContent || '').trim() !== text) break;
          node = parent;
        }
        return node;
      }

      function sweepAppBanners() {
        var selector = 'a:not([data-insta-no-reels-banner]), button:not([data-insta-no-reels-banner]), [role="button"]:not([data-insta-no-reels-banner]), [role="link"]:not([data-insta-no-reels-banner])';
        document.querySelectorAll(selector).forEach(function (el) {
          el.setAttribute('data-insta-no-reels-banner', 'checked');
          var href = el.getAttribute('href') || '';
          var label = (el.textContent || '').trim();
          if (APP_STORE_HREF.test(href) || APP_BANNER_LABELS.indexOf(label) !== -1) {
            hide(tightWrapper(el));
          }
        });
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

      // The mobile site labels ads "Ad" (under the username, in both the
      // feed and the story viewer); the desktop site uses "Sponsored".
      var SPONSORED_LABELS = ['Ad', 'Sponsored'];
      // Per-item labels: shown under a username on a single recommended
      // post, or as the title of an accounts carousel dropped in between
      // followed posts. Only that item gets hidden.
      var SUGGESTED_ITEM_LABELS = ['Suggested for you', 'Suggested reels', 'Suggested Reels', 'Suggested threads'];
      // Section labels: the divider after the last followed post. Every
      // feed item after it is a recommendation, so they all get hidden.
      var SUGGESTED_SECTION_LABELS = ['Suggested posts', 'Suggested Posts'];
      var HIDDEN_MARK = 'data-insta-no-reels-hidden';
      var DIVIDER_MARK = 'data-insta-no-reels-divider';
      var NOTE_MARK = 'data-insta-no-reels-note';

      function markHidden(el) {
        if (!el) return;
        el.setAttribute(HIDDEN_MARK, 'true');
        hide(el);
      }

      function isLargeMedia(img) {
        var rect = img.getBoundingClientRect();
        return rect.width >= window.innerWidth * 0.5 || rect.height >= 200;
      }

      function hasMedia(el) {
        if (el.querySelector('video')) return true;
        return Array.prototype.some.call(el.querySelectorAll('img'), isLargeMedia);
      }

      // Every feed post has exactly one Like control, so this is how many
      // posts an element spans.
      function likeCount(el) {
        return el.querySelectorAll('svg[aria-label="Like"], svg[aria-label="Unlike"]').length;
      }

      function isPageChrome(el) {
        return el === document.body || el.tagName === 'MAIN' ||
          el.querySelector('input, nav, [role="navigation"], header') !== null;
      }

      // Given a label ("Ad", "Suggested for you") somewhere in a post's
      // header, find the single feed item that contains it. Markup is
      // obfuscated and differs between the mobile and desktop layouts, so
      // this works structurally: climb until we hit the first ancestor
      // that also contains the post's media, then keep climbing while the
      // parent still looks like part of the same post (no sibling has its
      // own media, it isn't dramatically taller, and it still spans at
      // most one Like control). Never returns anything spanning multiple
      // posts — that's how the whole feed could vanish.
      function feedItemFor(el) {
        var node = el;
        var found = null;
        for (var i = 0; i < 15 && node && node !== document.body; i++) {
          if (node.tagName === 'ARTICLE') return likeCount(node) > 1 ? null : node;
          if (hasMedia(node)) {
            found = node;
            break;
          }
          node = node.parentElement;
        }
        if (!found || likeCount(found) > 1) return null;

        for (var j = 0; j < 8; j++) {
          var parent = found.parentElement;
          if (!parent || isPageChrome(parent)) break;
          if (likeCount(parent) > 1) break;
          var siblingHasMedia = Array.prototype.some.call(parent.children, function (child) {
            return child !== found && hasMedia(child);
          });
          if (siblingHasMedia) break;
          var grow = parent.getBoundingClientRect().height - found.getBoundingClientRect().height;
          if (grow > 150) break;
          found = parent;
        }
        return found;
      }

      // The top-level feed entry (direct child of the list of posts) that
      // contains `el`, for things that aren't posts: a "Suggested for you"
      // accounts carousel, or the "Suggested posts" divider. Climbs while
      // the parent holds no posts at all; stops before page chrome. Returns
      // null if it never reaches the post list (e.g. on a profile page),
      // so nothing page-sized ever gets hidden.
      function feedEntryFor(el) {
        var node = el;
        for (var i = 0; i < 15; i++) {
          var parent = node.parentElement;
          if (!parent || isPageChrome(parent)) return null;
          if (likeCount(parent) > 0) return node;
          node = parent;
        }
        return null;
      }

      function inStories() {
        return location.pathname.indexOf('/stories/') === 0;
      }

      // The story viewer isn't always at a /stories/ URL (it can open as
      // an overlay over the feed), so also recognise it structurally: a
      // dialog, or a fixed-position ancestor covering most of the screen.
      function isInOverlay(el) {
        if (el.closest('[role="dialog"]')) return true;
        var node = el;
        while (node && node !== document.body) {
          if (getComputedStyle(node).position === 'fixed' &&
              node.getBoundingClientRect().height >= window.innerHeight * 0.6) {
            return true;
          }
          node = node.parentElement;
        }
        return false;
      }

      function labelledElements(labels, root) {
        root = root || document.body;
        var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
        var matches = [];
        var node;
        while ((node = walker.nextNode())) {
          var text = (node.textContent || '').trim();
          if (!text || labels.indexOf(text) === -1) continue;
          var el = node.parentElement;
          if (!el || el.closest('[' + HIDDEN_MARK + ']')) continue;
          matches.push(el);
        }
        return matches;
      }

      // Ads in the feed: anything labelled "Ad" in a post's header. Labels
      // inside the story viewer are left alone — there the "post" holding
      // the label is the whole viewer, and story ads are skipped instead.
      function sweepSponsored() {
        if (inStories()) return;
        labelledElements(SPONSORED_LABELS).forEach(function (el) {
          if (isInOverlay(el)) return;
          var item = feedItemFor(el);
          if (item) markHidden(item);
        });
      }

      // Synthesize a full touch/pointer/mouse tap at a point, since a bare
      // .click() doesn't register with the story viewer's gesture handling.
      function tapAt(x, y) {
        var target = document.elementFromPoint(x, y);
        if (!target) return false;
        var pointer = { bubbles: true, cancelable: true, clientX: x, clientY: y, pointerId: 1, pointerType: 'touch', isPrimary: true, button: 0 };
        var touch = null;
        try { touch = new Touch({ identifier: 1, target: target, clientX: x, clientY: y }); } catch (e) {}
        function touchEvent(type, touches) {
          if (!touch) return;
          try {
            target.dispatchEvent(new TouchEvent(type, { bubbles: true, cancelable: true, touches: touches, targetTouches: touches, changedTouches: [touch] }));
          } catch (e) {}
        }
        try { target.dispatchEvent(new PointerEvent('pointerdown', pointer)); } catch (e) {}
        touchEvent('touchstart', [touch]);
        try { target.dispatchEvent(new MouseEvent('mousedown', pointer)); } catch (e) {}
        try { target.dispatchEvent(new PointerEvent('pointerup', pointer)); } catch (e) {}
        touchEvent('touchend', []);
        try { target.dispatchEvent(new MouseEvent('mouseup', pointer)); } catch (e) {}
        try { target.dispatchEvent(new MouseEvent('click', pointer)); } catch (e) {}
        return true;
      }

      // Story ads can't be blocked (Instagram serves them inline in the
      // story sequence), so the moment one is on screen, advance past it.
      // Keeps firing every tick while the "Ad" label is still on screen,
      // so multi-segment ads get tapped through segment by segment.
      // Alternates between the explicit "Next" control and a synthesized
      // tap on the right-hand side of the story.
      var STORY_SKIP_INTERVAL = 400;
      var lastStorySkip = 0;
      var storySkipAttempts = 0;
      function sweepStoryAds() {
        if (!flags.autoSkipStoryAds) return;
        var labels = labelledElements(SPONSORED_LABELS, document.body);
        var storyAd = null;
        for (var i = 0; i < labels.length; i++) {
          if (inStories() || isInOverlay(labels[i])) {
            storyAd = labels[i];
            break;
          }
        }
        if (!storyAd) {
          storySkipAttempts = 0;
          return;
        }
        var now = Date.now();
        if (now - lastStorySkip < STORY_SKIP_INTERVAL) return;
        lastStorySkip = now;
        storySkipAttempts++;

        var next = document.querySelector('button[aria-label="Next"], [role="button"][aria-label="Next"]');
        if (next && storySkipAttempts % 2 === 1) {
          next.click();
          return;
        }
        if (!tapAt(window.innerWidth * 0.85, window.innerHeight * 0.5) && next) {
          next.click();
        }
      }

      function insertCaughtUpNote(after) {
        if (after.nextElementSibling && after.nextElementSibling.hasAttribute(NOTE_MARK)) return;
        var note = document.createElement('div');
        note.setAttribute(NOTE_MARK, 'true');
        note.textContent = "You're all caught up — suggested posts are hidden.";
        note.style.cssText = 'padding:32px 24px;text-align:center;color:#8e8e8e;font-size:14px;line-height:1.4;';
        after.parentElement.insertBefore(note, after.nextSibling);
      }

      // Recommendations. Per-item labels hide just that post/carousel.
      // The "Suggested posts" divider marks the end of followed content:
      // it and everything after it get hidden, and a note takes its place
      // so the feed ending there doesn't look broken.
      function sweepSuggested() {
        if (inStories()) return;

        labelledElements(SUGGESTED_ITEM_LABELS).forEach(function (el) {
          if (isInOverlay(el)) return;
          var item = feedItemFor(el);
          if (!item && location.pathname === '/') item = feedEntryFor(el);
          if (item) markHidden(item);
        });

        if (location.pathname === '/') {
          labelledElements(SUGGESTED_SECTION_LABELS).forEach(function (el) {
            if (isInOverlay(el)) return;
            var entry = feedEntryFor(el);
            if (!entry) return;
            entry.setAttribute(DIVIDER_MARK, 'true');
            markHidden(entry);
            insertCaughtUpNote(entry);
          });

          // Infinite scroll keeps appending after the divider.
          document.querySelectorAll('[' + DIVIDER_MARK + ']').forEach(function (divider) {
            var sibling = divider.nextElementSibling;
            while (sibling) {
              if (!sibling.hasAttribute(NOTE_MARK) && !sibling.hasAttribute(HIDDEN_MARK)) markHidden(sibling);
              sibling = sibling.nextElementSibling;
            }
          });
        }
      }

      // Reels-format videos served into the home feed. Only on the home
      // feed — profile grids also link to /reel/ and must be left alone.
      function sweepFeedReels() {
        if (!flags.hideReelsInsideFeed || location.pathname !== '/') return;
        document.querySelectorAll('a[href^="/reel/"]').forEach(function (a) {
          if (a.closest('[' + HIDDEN_MARK + ']')) return;
          var item = feedItemFor(a);
          if (item) markHidden(item);
        });
      }

      var HOME_PATH = flags.homePath || '/?variant=following';

      function sweepNavIcons() {
        document.querySelectorAll('a[href="/reels/"], a[href^="/reels/?"], [aria-label="Reels"]').forEach(function (el) {
          hide(ancestor(el, 2));
        });

        // Home tab (and the wordmark link) go to the Following feed.
        document.querySelectorAll('a[href="/"]').forEach(function (a) {
          a.setAttribute('href', HOME_PATH);
        });

        document.querySelectorAll('a[href="/explore/"], a[href^="/explore/?"]').forEach(function (el) {
          if (flags.layout === 'mobile') {
            // This is the search tab on mobile — keep it, but send it to
            // the search page instead of the recommendation grid.
            if (el.getAttribute('href') !== SEARCH_PATH) el.setAttribute('href', SEARCH_PATH);
          } else {
            hide(ancestor(el, 2));
          }
        });

        if (flags.layout === 'desktop') {
          document.querySelectorAll('[aria-label="Explore"]').forEach(function (el) {
            hide(ancestor(el, 2));
          });
        }
      }

      // Bridge to the native side (see InstagramWebView.Coordinator).
      function postNative(message) {
        try {
          window.webkit.messageHandlers.instaNoReels.postMessage(message);
        } catch (e) {}
      }

      function clickableFor(el) {
        return el.closest('a, button, [role="button"], [role="link"]') || el.parentElement;
      }

      // Direct child of `container` that contains `el`.
      function childContaining(container, el) {
        var node = el;
        while (node && node.parentElement !== container) node = node.parentElement;
        return node;
      }

      // Force every wrapper between `el` and `row` to be non-positioned so
      // `el`'s absolute position resolves against the row.
      function placeInRow(row, el, styles) {
        var node = el.parentElement;
        while (node && node !== row) {
          node.style.setProperty('position', 'static', 'important');
          node = node.parentElement;
        }
        el.style.setProperty('position', 'absolute', 'important');
        el.style.setProperty('top', '50%', 'important');
        el.style.setProperty('margin', '0', 'important');
        Object.keys(styles).forEach(function (key) {
          el.style.setProperty(key, styles[key], 'important');
        });
      }

      // Make the feed header scroll away with the page instead of staying
      // pinned. Instagram pins either the <header> or a wrapper around it:
      // fixed → absolute keeps it at the top of the page (and the space
      // the page reserves for it still lines up); sticky → relative just
      // leaves it in the flow.
      function unstickHeader(header) {
        var node = header;
        for (var i = 0; i < 4 && node && node !== document.body; i++) {
          var position = getComputedStyle(node).position;
          if (position === 'fixed') {
            node.style.setProperty('position', 'absolute', 'important');
            node.style.setProperty('top', '0', 'important');
            return;
          }
          if (position === 'sticky') {
            node.style.setProperty('position', 'relative', 'important');
            return;
          }
          node = node.parentElement;
        }
      }

      // Rearrange the feed header to: "+" on the left, wordmark centered,
      // notifications on the right. Layout is obfuscated, so this finds the
      // three controls by their accessibility labels / links and pins each
      // one absolutely inside the header row instead of moving DOM nodes
      // (which React would fight). The wordmark's tap becomes the native
      // account switcher.
      function styleHeader() {
        var logo = document.querySelector('header svg[aria-label="Instagram"]');
        if (!logo) {
          // On the Following feed the header title can be the text
          // "Following" (with the chevron) instead of the wordmark.
          var headers = document.querySelectorAll('header');
          for (var h = 0; h < headers.length && !logo; h++) {
            logo = labelledElements(['Following', 'Favorites', 'Instagram'], headers[h])[0] || null;
          }
        }
        if (!logo) return;
        var header = logo.closest('header');
        var row = childContaining(header, logo);
        if (!row || row.getAttribute('data-insta-no-reels-header') === 'done') return;

        var create = header.querySelector('svg[aria-label="New post"], svg[aria-label="Create"], svg[aria-label="New Post"], a[href^="/create/"] svg');
        var notifications = header.querySelector('svg[aria-label="Notifications"], a[href="/accounts/activity/"] svg, a[href^="/notifications"] svg');

        var height = Math.max(row.getBoundingClientRect().height, 44);
        row.setAttribute('data-insta-no-reels-header', 'done');
        unstickHeader(header);
        row.style.setProperty('position', 'relative', 'important');
        row.style.setProperty('min-height', height + 'px', 'important');

        var logoWrap = clickableFor(logo);
        placeInRow(row, logoWrap, { left: '50%', transform: 'translate(-50%, -50%)' });
        if (!logoWrap.getAttribute('data-insta-no-reels-switch')) {
          logoWrap.setAttribute('data-insta-no-reels-switch', 'true');
          logoWrap.addEventListener('click', function (event) {
            event.preventDefault();
            event.stopPropagation();
            event.stopImmediatePropagation();
            postNative({ type: 'switchAccounts' });
          }, true);
        }

        if (create) {
          placeInRow(row, clickableFor(create), { left: '16px', transform: 'translateY(-50%)' });
        }
        if (notifications) {
          placeInRow(row, clickableFor(notifications), { right: '16px', transform: 'translateY(-50%)' });
        }
      }

      // Tell the native side which account this data store is logged in
      // as, so the switcher can label it. The profile tab in the bottom nav
      // carries an avatar whose alt text is "<username>'s profile picture".
      var lastReportedUsername = '';
      function reportUsername() {
        var img = document.querySelector('nav img[alt$="profile picture"], [role="navigation"] img[alt$="profile picture"]');
        if (!img) return;
        var alt = img.getAttribute('alt') || '';
        var username = alt.replace(/['’]s profile picture$/, '').trim();
        if (!username || username === lastReportedUsername) return;
        lastReportedUsername = username;
        postNative({ type: 'username', value: username });
      }

      // On the search page itself, drop hashtag / place / audio results so
      // only accounts remain (the JSON filter in bootstrap handles most of
      // this; this catches anything rendered from cached or inline data).
      function sweepSearchPage() {
        if (location.pathname.indexOf('/explore') !== 0) return;
        document.querySelectorAll('a[href^="/explore/tags/"], a[href^="/explore/locations/"], a[href^="/reels/audio/"]').forEach(function (a) {
          hide(tightWrapper(a));
        });

        // The search page also carries a suggestion grid of reels/posts
        // under the search box (and post results after typing). Hide the
        // whole grid section: climb from a tile to its outermost container
        // that doesn't also hold page chrome (search box, nav, header).
        function isPageChrome(el) {
          return el === document.body || el.tagName === 'MAIN' ||
            el.querySelector('input, nav, [role="navigation"], header') !== null;
        }
        document.querySelectorAll('a[href^="/reel/"], a[href^="/p/"]').forEach(function (a) {
          if (a.closest('[' + HIDDEN_MARK + ']')) return;
          var node = a;
          while (node.parentElement && !isPageChrome(node.parentElement)) {
            node = node.parentElement;
          }
          markHidden(node);
        });
      }

      // Put the search page straight into Instagram's "search focused"
      // state (Recent list + Cancel), which is what replaces the
      // suggestion grid. Programmatic focus doesn't raise the keyboard in
      // WKWebView, so this just swaps the content. Retries a few times per
      // page in case the box isn't rendered yet.
      var lastSearchActivate = 0;
      var searchActivateAttempts = 0;
      var searchActivatePath = '';
      function activateSearch() {
        if (location.pathname.indexOf('/explore') !== 0) {
          searchActivatePath = '';
          return;
        }
        if (searchActivatePath !== location.pathname) {
          searchActivatePath = location.pathname;
          searchActivateAttempts = 0;
        }
        if (searchActivateAttempts >= 6) return;

        var inSearchMode = Array.prototype.some.call(
          document.querySelectorAll('button, [role="button"], a'),
          function (el) { return (el.textContent || '').trim() === 'Cancel'; }
        );
        if (inSearchMode) return;

        var now = Date.now();
        if (now - lastSearchActivate < 1000) return;
        lastSearchActivate = now;
        searchActivateAttempts++;

        var input = document.querySelector('input[type="search"], input[placeholder*="Search" i], input[aria-label*="Search" i], main input[type="text"]');
        if (input) {
          input.click();
          input.focus();
          return;
        }
        // The box may be a button that turns into an input once tapped.
        // Skip the nav bar's own search icon.
        var icons = document.querySelectorAll('svg[aria-label="Search"]');
        for (var i = 0; i < icons.length; i++) {
          if (icons[i].closest('nav, [role="navigation"]')) continue;
          var target = clickableFor(icons[i]);
          if (target) {
            target.click();
            return;
          }
        }
      }

      // Jump to the home feed via Instagram's own Home tab (instant SPA
      // navigation); hard-navigate as a fallback.
      function goHome() {
        var home = document.querySelector('svg[aria-label="Home"]');
        var link = home ? clickableFor(home) : null;
        if (link) {
          link.click();
          return;
        }
        window.location.assign(HOME_PATH);
      }

      // "Cancel" on the search page normally drops back to the suggestion
      // grid. Make it go home instead, so the grid is never reachable.
      function hookSearchCancel() {
        if (location.pathname.indexOf('/explore') !== 0) return;
        var controls = document.querySelectorAll('button:not([data-insta-no-reels-cancel]), [role="button"]:not([data-insta-no-reels-cancel]), a:not([data-insta-no-reels-cancel])');
        for (var i = 0; i < controls.length; i++) {
          var el = controls[i];
          if ((el.textContent || '').trim() !== 'Cancel') continue;
          el.setAttribute('data-insta-no-reels-cancel', 'true');
          el.addEventListener('click', function (event) {
            event.preventDefault();
            event.stopPropagation();
            event.stopImmediatePropagation();
            goHome();
          }, true);
        }
      }

      // Count feed posts as they scroll into view. Every feed post has
      // exactly one Like control; when it enters the viewport, the post
      // it belongs to counts once. Posts are keyed by permalink so a
      // virtualized feed re-rendering the same post doesn't double count,
      // and anything already hidden (ads, suggested) doesn't count at all.
      var countedPosts = {};
      function sweepPostCounter() {
        if (location.pathname !== '/') return;
        var viewportHeight = window.innerHeight;
        var likes = document.querySelectorAll('svg[aria-label="Like"]:not([data-insta-no-reels-counted]), svg[aria-label="Unlike"]:not([data-insta-no-reels-counted])');
        for (var i = 0; i < likes.length; i++) {
          var svg = likes[i];
          var rect = svg.getBoundingClientRect();
          if (rect.bottom <= 0 || rect.top >= viewportHeight) continue;
          svg.setAttribute('data-insta-no-reels-counted', 'true');

          var item = feedItemFor(svg) || ancestor(svg, 6);
          if (item.closest('[' + HIDDEN_MARK + ']')) continue;

          var link = item.querySelector('a[href^="/p/"], a[href^="/reel/"]');
          var key = link ? link.getAttribute('href') : null;
          if (!key) {
            var avatar = item.querySelector('img[alt$="profile picture"]');
            key = (avatar ? avatar.getAttribute('alt') : 'post') + '|' + Math.round(rect.top + window.scrollY);
          }
          if (countedPosts[key]) continue;
          countedPosts[key] = true;
          postNative({ type: 'postViewed' });
        }
      }

      var postCounterQueued = false;
      function schedulePostCounter() {
        if (postCounterQueued) return;
        postCounterQueued = true;
        setTimeout(function () {
          postCounterQueued = false;
          sweepPostCounter();
        }, 200);
      }

      var sweepQueued = false;
      function scheduleSweep() {
        if (sweepQueued) return;
        sweepQueued = true;
        // Coalesce bursts of DOM mutations (Instagram fires a lot while
        // scrolling) into one pass every ~150ms.
        setTimeout(function () {
          sweepQueued = false;
          sweepSponsored();
          sweepSuggested();
          sweepFeedReels();
          sweepStoryAds();
          sweepNavIcons();
          sweepSearchPage();
          activateSearch();
          hookSearchCancel();
          sweepAppBanners();
          styleHeader();
          reportUsername();
          sweepPostCounter();
          applyViewport();
        }, 150);
      }

      function start() {
        injectStyle();
        applyViewport();
        scheduleSweep();
        new MutationObserver(scheduleSweep).observe(document.body, {
          childList: true,
          subtree: true
        });
        // Plain scrolling doesn't mutate the DOM, but it's what brings
        // posts into view for the counter. Capture phase so inner
        // scrollers are covered too.
        document.addEventListener('scroll', schedulePostCounter, { capture: true, passive: true });
        // A playing story ad doesn't necessarily mutate the DOM, so poll
        // for it too (cheap: returns immediately outside the story viewer).
        // Same for the search page, whose focus state may need a nudge
        // after the page settles.
        setInterval(function () {
          sweepStoryAds();
          activateSearch();
        }, STORY_SKIP_INTERVAL);
      }

      if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', start);
      } else {
        start();
      }
    })();
    """#
}
