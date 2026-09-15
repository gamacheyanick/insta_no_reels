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
              var path = new URL(url, location.href).pathname;
              if (flags.layout === 'mobile' && isExploreRoot(path)) {
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
      var SUGGESTED_LABELS = [
        'Suggested for you', 'Suggested posts', 'Suggested Posts',
        'Suggested reels', 'Suggested Reels', 'Suggested threads'
      ];
      var HIDDEN_MARK = 'data-insta-no-reels-hidden';

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

      // Given a label ("Sponsored", "Suggested for you") somewhere in a
      // post's header, find the whole feed item that contains it. Markup
      // is obfuscated and differs between the mobile and desktop layouts,
      // so this works structurally: climb until we hit the first ancestor
      // that also contains the post's media, then keep climbing while the
      // parent still looks like part of the same post (no sibling has its
      // own media, and it isn't dramatically taller). Stops at <article>
      // immediately when the layout uses it.
      function feedItemFor(el) {
        var node = el;
        var found = null;
        for (var i = 0; i < 15 && node && node !== document.body; i++) {
          if (node.tagName === 'ARTICLE') return node;
          if (hasMedia(node)) {
            found = node;
            break;
          }
          node = node.parentElement;
        }
        if (!found) return null;

        for (var j = 0; j < 8; j++) {
          var parent = found.parentElement;
          if (!parent || parent === document.body || parent.tagName === 'MAIN') break;
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

      function inStories() {
        return location.pathname.indexOf('/stories/') === 0;
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

      // Ads: anything labelled "Sponsored" in its header. Not in the story
      // viewer — there the "post" containing the label is the whole viewer,
      // so story ads get skipped instead (sweepStoryAds).
      function sweepSponsored() {
        if (inStories()) return;
        labelledElements(SPONSORED_LABELS).forEach(function (el) {
          var item = feedItemFor(el);
          if (item) markHidden(item);
        });
      }

      // Story ads can't be blocked (Instagram serves them inline in the
      // story sequence), so the moment one is on screen, advance past it.
      // This keeps firing every tick while the "Sponsored" label is still
      // on screen, so multi-segment ads get tapped through segment by
      // segment. It alternates between the explicit "Next" control and a
      // tap on the right-hand side of the story, so whichever one the
      // current layout actually responds to gets tried within a tick.
      var STORY_SKIP_INTERVAL = 400;
      var lastStorySkip = 0;
      var storySkipAttempts = 0;
      function sweepStoryAds() {
        if (!inStories()) {
          storySkipAttempts = 0;
          return;
        }
        if (labelledElements(SPONSORED_LABELS, document.body).length === 0) {
          storySkipAttempts = 0;
          return;
        }
        var now = Date.now();
        if (now - lastStorySkip < STORY_SKIP_INTERVAL) return;
        lastStorySkip = now;
        storySkipAttempts++;

        var next = document.querySelector('button[aria-label="Next"], [role="button"][aria-label="Next"]');
        var useNextButton = next && storySkipAttempts % 2 === 1;
        if (useNextButton) {
          next.click();
          return;
        }
        var target = document.elementFromPoint(window.innerWidth * 0.85, window.innerHeight * 0.5);
        if (target) {
          target.click();
        } else if (next) {
          next.click();
        }
      }

      // Recommendations: suggested posts get hidden as whole feed items;
      // "Suggested for you" account carousels (no big media) fall back to
      // hiding the labelled block.
      function sweepSuggested() {
        labelledElements(SUGGESTED_LABELS).forEach(function (el) {
          markHidden(feedItemFor(el) || ancestor(el, 5));
        });
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

      function sweepNavIcons() {
        document.querySelectorAll('a[href="/reels/"], a[href^="/reels/?"], [aria-label="Reels"]').forEach(function (el) {
          hide(ancestor(el, 2));
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

      // Rearrange the feed header to: "+" on the left, wordmark centered,
      // notifications on the right. Layout is obfuscated, so this finds the
      // three controls by their accessibility labels / links and pins each
      // one absolutely inside the header row instead of moving DOM nodes
      // (which React would fight). The wordmark's tap becomes the native
      // account switcher.
      function styleHeader() {
        var logo = document.querySelector('header svg[aria-label="Instagram"]');
        if (!logo) return;
        var header = logo.closest('header');
        var row = childContaining(header, logo);
        if (!row || row.getAttribute('data-insta-no-reels-header') === 'done') return;

        var create = header.querySelector('svg[aria-label="New post"], svg[aria-label="Create"], svg[aria-label="New Post"], a[href^="/create/"] svg');
        var notifications = header.querySelector('svg[aria-label="Notifications"], a[href="/accounts/activity/"] svg, a[href^="/notifications"] svg');

        var height = Math.max(row.getBoundingClientRect().height, 44);
        row.setAttribute('data-insta-no-reels-header', 'done');
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
        window.location.assign('/');
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
