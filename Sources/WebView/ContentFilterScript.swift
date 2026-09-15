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
          headerScrollsAway: \(AppConfig.headerScrollsAway),
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
              if (leavingStoryFor(path)) {
                return; // chained to the next story instead
              }
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
      // Stories opened from the app's story row are direct /stories/<user>/
      // loads, which Instagram plays in isolation and then exits to "/".
      // The row stores its order; when Instagram tries to leave a story
      // for "/", go to the next person instead (Following feed after the
      // last one). Users not in the row (e.g. opened from a profile) are
      // left to Instagram.
      var STORY_ORDER_KEY = 'insta-no-reels-story-order';
      function storyUsername(path) {
        var match = /^\/stories\/([^\/]+)\/?/.exec(path || '');
        return match ? match[1] : null;
      }
      function pathAfterStory() {
        var current = storyUsername(location.pathname);
        if (!current) return null;
        var order = [];
        try { order = JSON.parse(sessionStorage.getItem(STORY_ORDER_KEY) || '[]'); } catch (e) {}
        var index = order.indexOf(current);
        if (index === -1) return null;
        return index + 1 < order.length ? '/stories/' + order[index + 1] + '/' : (flags.homePath || '/?variant=following');
      }
      function leavingStoryFor(path) {
        if (path !== '/' || !storyUsername(location.pathname)) return false;
        var next = pathAfterStory();
        if (!next) return false;
        window.location.assign(next);
        return true;
      }

      guardHistoryMethod('pushState');
      guardHistoryMethod('replaceState');

      // Hide the Reels tab from the very first paint. The cleanup script
      // also injects this, but only once the DOM is ready — that gap was
      // enough to see (and tap) the tab.
      function injectEarlyStyle() {
        var root = document.head || document.documentElement;
        if (!root) {
          setTimeout(injectEarlyStyle, 0);
          return;
        }
        var style = document.createElement('style');
        style.setAttribute('data-insta-no-reels-early', 'true');
        style.textContent = 'a[href="/reels/"], a[href^="/reels/?"], [aria-label="Reels"] { display: none !important; }';
        root.appendChild(style);
      }
      injectEarlyStyle();

      // Blocking the URL update isn't enough on its own: Instagram's
      // router switches to the Reels view before it calls pushState. So
      // the tap itself is swallowed, in the capture phase, before any of
      // Instagram's handlers run.
      document.addEventListener('click', function (event) {
        var target = event.target;
        if (!target || !target.closest) return;
        if (!target.closest('a[href^="/reels"], [aria-label="Reels"]')) return;
        event.preventDefault();
        event.stopPropagation();
        event.stopImmediatePropagation();
      }, true);

      var previousPath = location.pathname;
      window.addEventListener('popstate', function () {
        var cameFromStory = storyUsername(previousPath);
        previousPath = location.pathname;
        if (cameFromStory && location.pathname === '/') {
          // Instagram backed out of a story with history navigation.
          var order = [];
          try { order = JSON.parse(sessionStorage.getItem(STORY_ORDER_KEY) || '[]'); } catch (e) {}
          var index = order.indexOf(cameFromStory);
          if (index !== -1) {
            window.location.replace(index + 1 < order.length ? '/stories/' + order[index + 1] + '/' : (flags.homePath || '/?variant=following'));
            return;
          }
        }
        if (location.pathname === '/') {
          // History navigation (e.g. back from Messages) lets Instagram's
          // router render the ranked feed regardless of the query string.
          window.location.replace(flags.homePath || '/?variant=following');
          return;
        }
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

    /// In-app story viewer, used by the app-built story row on the
    /// Following feed. Fetches each person's story items from Instagram's
    /// reels endpoint (same session), plays them in sequence across people
    /// with no page loads, and marks them seen. Exposed to `cleanup` as
    /// `window.__instaNoReelsViewer`.
    static let viewer = #"""
    (function () {
      'use strict';

      var IG_APP_ID = '936619743392459';
      var IMAGE_DURATION = 5000;
      var HOLD_DELAY = 220;
      var MARK = 'data-insta-no-reels-viewer';

      function igFetch(path) {
        return fetch(path, {
          credentials: 'include',
          headers: { 'x-ig-app-id': IG_APP_ID, 'x-requested-with': 'XMLHttpRequest', 'accept': 'application/json' }
        }).then(function (response) { return response.ok ? response.json() : null; });
      }

      function csrfToken() {
        var match = /(?:^|;\s*)csrftoken=([^;]+)/.exec(document.cookie || '');
        return match ? match[1] : '';
      }

      function timeAgo(takenAt) {
        var diff = Math.max(0, Math.floor(Date.now() / 1000 - takenAt));
        if (diff < 60) return diff + 's';
        if (diff < 3600) return Math.floor(diff / 60) + 'm';
        if (diff < 86400) return Math.floor(diff / 3600) + 'h';
        return Math.floor(diff / 86400) + 'd';
      }

      function bestImage(item) {
        var candidates = item.image_versions2 && item.image_versions2.candidates;
        return candidates && candidates.length ? candidates[0].url : '';
      }

      function bestVideo(item) {
        var versions = item.video_versions;
        return versions && versions.length ? versions[0].url : '';
      }

      // ---- Data ------------------------------------------------------
      var reelCache = {};
      function loadReel(reel) {
        var key = String(reel.userPk);
        if (reelCache[key]) return reelCache[key];
        reelCache[key] = igFetch('/api/v1/feed/reels_media/?reel_ids=' + encodeURIComponent(key)).then(function (json) {
          var data = null;
          if (json && Array.isArray(json.reels_media) && json.reels_media.length) data = json.reels_media[0];
          else if (json && json.reels && json.reels[key]) data = json.reels[key];
          var items = data && Array.isArray(data.items) ? data.items : [];
          return { reelId: data && data.id ? String(data.id) : key, items: items };
        }).catch(function () {
          delete reelCache[key];
          return { reelId: key, items: [] };
        });
        return reelCache[key];
      }

      function markSeen(reel, reelId, item) {
        var csrf = csrfToken();
        if (!csrf || !item) return;
        var body = new URLSearchParams({
          reelMediaId: String(item.pk || ''),
          reelMediaOwnerId: String(reel.userPk),
          reelId: String(reelId),
          reelMediaTakenAt: String(item.taken_at || 0),
          viewSeenAt: String(Math.floor(Date.now() / 1000))
        });
        fetch('/stories/reel/seen', {
          method: 'POST',
          credentials: 'include',
          headers: {
            'x-csrftoken': csrf,
            'x-ig-app-id': IG_APP_ID,
            'x-requested-with': 'XMLHttpRequest',
            'content-type': 'application/x-www-form-urlencoded'
          },
          body: body.toString()
        }).catch(function () {});
      }

      // ---- UI --------------------------------------------------------
      var ui = null;
      var state = null;

      function el(tag, style, attrs) {
        var node = document.createElement(tag);
        if (style) node.style.cssText = style;
        if (attrs) Object.keys(attrs).forEach(function (key) { node.setAttribute(key, attrs[key]); });
        return node;
      }

      function buildUI() {
        var root = el('div', 'position:fixed;inset:0;z-index:2147483000;background:#000;color:#fff;font-family:-apple-system,system-ui,sans-serif;-webkit-user-select:none;user-select:none;touch-action:none;overflow:hidden;');
        root.setAttribute(MARK, 'true');

        var style = document.createElement('style');
        style.textContent = '@keyframes inr-spin{to{transform:rotate(360deg)}}';
        root.appendChild(style);

        var media = el('div', 'position:absolute;inset:0;display:flex;align-items:center;justify-content:center;');
        var img = el('img', 'max-width:100%;max-height:100%;object-fit:contain;display:none;', { alt: '' });
        var video = el('video', 'max-width:100%;max-height:100%;object-fit:contain;display:none;', { playsinline: '', 'webkit-playsinline': '', preload: 'auto' });
        var loading = el('div', 'position:absolute;width:28px;height:28px;border:3px solid rgba(255,255,255,.3);border-top-color:#fff;border-radius:50%;animation:inr-spin .8s linear infinite;');
        media.appendChild(img);
        media.appendChild(video);
        media.appendChild(loading);
        root.appendChild(media);

        var top = el('div', 'position:absolute;left:0;right:0;top:0;padding:10px 10px 24px;background:linear-gradient(rgba(0,0,0,.55),rgba(0,0,0,0));');
        var progress = el('div', 'display:flex;gap:3px;height:2px;');
        var bar = el('div', 'display:flex;align-items:center;gap:10px;margin-top:12px;');
        var avatar = el('img', 'width:32px;height:32px;border-radius:50%;object-fit:cover;background:#333;', { alt: '' });
        var name = el('span', 'font-weight:600;font-size:14px;');
        var time = el('span', 'opacity:.7;font-size:14px;');
        var spacer = el('span', 'flex:1;');
        var mute = el('button', 'background:none;border:0;color:#fff;font-size:20px;padding:4px 8px;line-height:1;');
        var close = el('button', 'background:none;border:0;color:#fff;font-size:30px;padding:0 6px;line-height:1;');
        close.textContent = '×';
        bar.appendChild(avatar);
        bar.appendChild(name);
        bar.appendChild(time);
        bar.appendChild(spacer);
        bar.appendChild(mute);
        bar.appendChild(close);
        top.appendChild(progress);
        top.appendChild(bar);
        root.appendChild(top);

        ui = { root: root, media: media, img: img, video: video, loading: loading, progress: progress, avatar: avatar, name: name, time: time, mute: mute, close: close };

        close.addEventListener('click', function (event) { event.stopPropagation(); closeViewer(); });
        mute.addEventListener('click', function (event) {
          event.stopPropagation();
          state.muted = !state.muted;
          video.muted = state.muted;
          renderMute();
        });
        // Keep taps on the header from counting as story navigation.
        top.addEventListener('pointerdown', function (event) { event.stopPropagation(); });

        media.addEventListener('pointerdown', onPointerDown);
        media.addEventListener('pointerup', onPointerUp);
        media.addEventListener('pointercancel', onPointerCancel);
        video.addEventListener('ended', function () { if (state && !state.paused) next(); });
        video.addEventListener('loadedmetadata', function () { if (state) hideLoading(); });
        video.addEventListener('waiting', function () { if (state) showLoading(); });
        video.addEventListener('playing', function () {
          if (!state) return;
          hideLoading();
          // Re-apply the user's sound preference once playback is going.
          if (!state.muted && video.muted) video.muted = false;
        });
      }

      function renderMute() {
        ui.mute.textContent = state.muted ? '🔇' : '🔊';
        ui.mute.style.display = state.currentIsVideo ? '' : 'none';
      }

      function showLoading() { ui.loading.style.display = ''; }
      function hideLoading() { ui.loading.style.display = 'none'; }

      // ---- Gestures: tap = prev/next, hold = pause, swipe down = close,
      // swipe sideways = prev/next person.
      var pointer = null;
      function onPointerDown(event) {
        if (!state) return;
        pointer = { x: event.clientX, y: event.clientY, at: Date.now(), held: false, timer: null };
        pointer.timer = setTimeout(function () {
          if (!pointer) return;
          pointer.held = true;
          pause();
        }, HOLD_DELAY);
      }

      function onPointerUp(event) {
        if (!state || !pointer) return;
        clearTimeout(pointer.timer);
        var dx = event.clientX - pointer.x;
        var dy = event.clientY - pointer.y;
        var held = pointer.held;
        pointer = null;
        if (held) {
          resume();
          return;
        }
        if (Math.abs(dx) > 60 && Math.abs(dx) > Math.abs(dy)) {
          if (dx < 0) showUser(state.userIndex + 1, false); else showUser(state.userIndex - 1, false);
          return;
        }
        if (dy > 80) {
          closeViewer();
          return;
        }
        if (event.clientX < window.innerWidth / 3) prev(); else next();
      }

      function onPointerCancel() {
        if (pointer) clearTimeout(pointer.timer);
        if (pointer && pointer.held) resume();
        pointer = null;
      }

      // ---- Playback --------------------------------------------------
      function stopTimer() {
        if (state && state.raf) cancelAnimationFrame(state.raf);
        if (state) state.raf = 0;
      }

      function setFill(index, fraction) {
        var bars = ui.progress.children;
        for (var i = 0; i < bars.length; i++) {
          var fill = bars[i].firstChild;
          fill.style.width = i < index ? '100%' : (i === index ? (Math.min(1, Math.max(0, fraction)) * 100) + '%' : '0%');
        }
      }

      function tick() {
        if (!state || state.paused) return;
        var fraction;
        if (state.currentIsVideo) {
          var duration = ui.video.duration;
          fraction = duration ? ui.video.currentTime / duration : 0;
        } else {
          var elapsed = state.elapsedBeforePause + (Date.now() - state.startedAt);
          fraction = elapsed / IMAGE_DURATION;
          if (fraction >= 1) {
            setFill(state.itemIndex, 1);
            next();
            return;
          }
        }
        setFill(state.itemIndex, fraction);
        state.raf = requestAnimationFrame(tick);
      }

      function pause() {
        if (!state || state.paused) return;
        state.paused = true;
        if (state.currentIsVideo) ui.video.pause();
        else state.elapsedBeforePause += Date.now() - state.startedAt;
        stopTimer();
      }

      function resume() {
        if (!state || !state.paused) return;
        state.paused = false;
        if (state.currentIsVideo) ui.video.play().catch(function () {});
        else state.startedAt = Date.now();
        tick();
      }

      function buildProgress(count) {
        ui.progress.innerHTML = '';
        for (var i = 0; i < count; i++) {
          var track = el('div', 'flex:1;background:rgba(255,255,255,.35);border-radius:2px;overflow:hidden;');
          var fill = el('div', 'width:0%;height:100%;background:#fff;');
          track.appendChild(fill);
          ui.progress.appendChild(track);
        }
      }

      function preload(item) {
        if (!item) return;
        if (item.media_type === 2 && bestVideo(item)) {
          var v = document.createElement('video');
          v.preload = 'auto';
          v.muted = true;
          v.src = bestVideo(item);
        } else if (bestImage(item)) {
          var i = new Image();
          i.src = bestImage(item);
        }
      }

      function showItem() {
        stopTimer();
        var reel = state.reels[state.userIndex];
        var item = state.items[state.itemIndex];
        if (!item) { next(); return; }

        ui.avatar.src = reel.pic || '';
        ui.name.textContent = reel.username;
        ui.time.textContent = item.taken_at ? timeAgo(item.taken_at) : '';
        setFill(state.itemIndex, 0);
        state.paused = false;
        state.elapsedBeforePause = 0;

        var videoURL = item.media_type === 2 ? bestVideo(item) : '';
        state.currentIsVideo = !!videoURL;
        renderMute();

        if (videoURL) {
          ui.img.style.display = 'none';
          ui.img.removeAttribute('src');
          ui.video.style.display = 'block';
          ui.video.muted = state.muted;
          ui.video.src = videoURL;
          showLoading();
          ui.video.play().catch(function (error) {
            if (!state || (error && error.name === 'AbortError')) return;
            // This attempt was refused with sound: play it muted, but keep
            // the user's preference so the next video tries with sound
            // again (and this one is unmuted once playing, see below).
            ui.video.muted = true;
            ui.video.play().catch(function () {});
          });
        } else {
          ui.video.pause();
          ui.video.removeAttribute('src');
          ui.video.load();
          ui.video.style.display = 'none';
          ui.img.style.display = 'block';
          showLoading();
          var url = bestImage(item);
          var token = ++state.loadToken;
          var image = new Image();
          image.onload = image.onerror = function () {
            if (!state || token !== state.loadToken) return;
            ui.img.src = url;
            hideLoading();
            state.startedAt = Date.now();
          };
          image.src = url;
          state.startedAt = Date.now() + 60000; // holds the bar at 0 until loaded
        }
        tick();

        markSeen(reel, state.reelId, item);
        preload(state.items[state.itemIndex + 1]);
        if (state.itemIndex === state.items.length - 1 && state.reels[state.userIndex + 1]) {
          loadReel(state.reels[state.userIndex + 1]).then(function (data) { preload(data.items[0]); });
        }
      }

      function showUser(index, fromEnd) {
        if (!state) return;
        if (index < 0) { index = 0; fromEnd = false; }
        if (index >= state.reels.length) { closeViewer(); return; }
        stopTimer();
        var direction = index >= state.userIndex ? 1 : -1;
        state.userIndex = index;
        var reel = state.reels[index];
        var token = ++state.loadToken;
        showLoading();
        ui.progress.innerHTML = '';
        ui.avatar.src = reel.pic || '';
        ui.name.textContent = reel.username;
        ui.time.textContent = '';

        loadReel(reel).then(function (data) {
          if (!state || token !== state.loadToken) return;
          if (!data.items.length) {
            // Nothing to show (expired, or the request failed): skip past.
            var nextIndex = index + direction;
            if (nextIndex < 0 || nextIndex >= state.reels.length) closeViewer(); else showUser(nextIndex, fromEnd);
            return;
          }
          state.items = data.items;
          state.reelId = data.reelId;
          state.itemIndex = fromEnd ? data.items.length - 1 : 0;
          buildProgress(data.items.length);
          showItem();
        });
      }

      function next() {
        if (!state) return;
        if (state.itemIndex + 1 < state.items.length) {
          state.itemIndex += 1;
          showItem();
        } else {
          var reel = state.reels[state.userIndex];
          if (state.onUserSeen) { try { state.onUserSeen(reel.username); } catch (e) {} }
          showUser(state.userIndex + 1, false);
        }
      }

      function prev() {
        if (!state) return;
        if (state.itemIndex > 0) {
          state.itemIndex -= 1;
          showItem();
        } else if (state.userIndex > 0) {
          showUser(state.userIndex - 1, true);
        } else {
          showItem(); // restart the first one
        }
      }

      function closeViewer() {
        if (!state) return;
        stopTimer();
        ui.video.pause();
        ui.video.removeAttribute('src');
        ui.video.load();
        ui.img.removeAttribute('src');
        ui.root.remove();
        document.documentElement.style.overflow = state.previousOverflow;
        state = null;
      }

      function open(reels, startIndex, onUserSeen) {
        if (!reels || !reels.length) return false;
        if (!ui) buildUI();
        if (state) closeViewer();
        state = {
          reels: reels,
          userIndex: startIndex || 0,
          itemIndex: 0,
          items: [],
          reelId: '',
          paused: false,
          muted: false,
          currentIsVideo: false,
          startedAt: 0,
          elapsedBeforePause: 0,
          raf: 0,
          loadToken: 0,
          onUserSeen: onUserSeen,
          previousOverflow: document.documentElement.style.overflow
        };
        document.documentElement.style.overflow = 'hidden';
        document.body.appendChild(ui.root);
        showUser(state.userIndex, false);
        return true;
      }

      window.__instaNoReelsViewer = { open: open, close: closeViewer, isOpen: function () { return !!state; } };
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

      // The story tray must never be collateral damage of any hiding rule,
      // whatever wrapper Instagram happens to put it in.
      function containsStories(el) {
        return !!(el && el.querySelector && el.querySelector('a[href^="/stories/"]'));
      }

      function hide(el) {
        if (!el || !el.style || containsStories(el)) return;
        el.style.setProperty('display', 'none', 'important');
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

      // Several sweeps look for short labels ("Ad", "Suggested for you",
      // "Your note"...). Walking the whole page's text once per sweep and
      // indexing it is far cheaper than one walk per label set — that
      // difference is felt as scroll jank on a long feed.
      var labelIndex = null;
      function buildLabelIndex() {
        var index = {};
        var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
        var node;
        while ((node = walker.nextNode())) {
          var text = (node.textContent || '').trim();
          if (!text || text.length > 40) continue;
          (index[text] || (index[text] = [])).push(node.parentElement);
        }
        return index;
      }

      function usableLabel(el) {
        return el && el.isConnected &&
          !el.closest('[' + HIDDEN_MARK + ']') &&
          !el.closest('[data-insta-no-reels-viewer]');
      }

      function labelledElements(labels, root) {
        if (!root || root === document.body) {
          if (!labelIndex) labelIndex = buildLabelIndex();
          var found = [];
          labels.forEach(function (label) {
            (labelIndex[label] || []).forEach(function (el) { if (usableLabel(el)) found.push(el); });
          });
          return found;
        }
        var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
        var matches = [];
        var node;
        while ((node = walker.nextNode())) {
          var text = (node.textContent || '').trim();
          if (!text || labels.indexOf(text) === -1) continue;
          if (usableLabel(node.parentElement)) matches.push(node.parentElement);
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
        if (!inStories() && !document.querySelector('[role="dialog"], [aria-modal="true"]')) {
          storySkipAttempts = 0;
          return;
        }
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
        document.querySelectorAll('a[href^="/reel/"]:not([data-insta-no-reels-reel])').forEach(function (a) {
          a.setAttribute('data-insta-no-reels-reel', 'checked');
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
        // Instagram's router ignores the rewritten href and renders the
        // ranked feed anyway, so the tap itself is intercepted and turned
        // into a real navigation.
        document.querySelectorAll('a[href="/"]').forEach(function (a) {
          a.setAttribute('href', HOME_PATH);
        });
        var homeIcon = document.querySelector('svg[aria-label="Home"]');
        var homeTab = homeIcon ? clickableFor(homeIcon) : null;
        if (homeTab && !homeTab.getAttribute('data-insta-no-reels-home')) {
          homeTab.setAttribute('data-insta-no-reels-home', 'true');
          homeTab.addEventListener('click', function (event) {
            event.preventDefault();
            event.stopPropagation();
            event.stopImmediatePropagation();
            // Always a real load: after an in-app navigation the URL can
            // say "following" while Instagram is actually rendering the
            // ranked feed, so the URL alone can't be trusted.
            window.location.assign(HOME_PATH);
          }, true);
        }

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
      // pinned. Only the <header> element itself is touched — never its
      // wrappers, which on the mobile site also host the story viewer
      // overlay. Rather than changing positioning (which breaks those
      // overlays), the header is slid up by however far the feed has
      // scrolled, capped at its own height: visually identical to a
      // non-sticky header, no layout side effects.
      function unstickHeader(header) {
        if (header.getAttribute('data-insta-no-reels-unstuck')) return;
        header.setAttribute('data-insta-no-reels-unstuck', 'true');

        var headerHeight = 0;
        var feedScroller = null;
        function feedScrollTop(event) {
          var y = window.scrollY || document.documentElement.scrollTop || 0;
          var target = event && event.target;
          // The feed may scroll inside a container rather than the
          // document; recognise that scroller by the posts it holds —
          // checked at most every couple of seconds per element, never on
          // every scroll event.
          if (target && target !== document && target.scrollTop !== undefined) {
            if (target !== feedScroller) {
              var now = Date.now();
              if (!target.__inrCheckedAt || now - target.__inrCheckedAt > 2000) {
                target.__inrCheckedAt = now;
                if (likeCount(target) > 0) feedScroller = target;
              }
            }
            if (target === feedScroller) y = Math.max(y, target.scrollTop);
          }
          return y;
        }

        function update(event) {
          if (!headerHeight) headerHeight = header.getBoundingClientRect().height || 44;
          var offset = Math.min(Math.max(feedScrollTop(event), 0), headerHeight);
          header.style.setProperty('transform', 'translateY(-' + offset + 'px)', 'important');
        }

        document.addEventListener('scroll', update, { capture: true, passive: true });
        window.addEventListener('resize', function () { headerHeight = 0; });
        update();
      }

      // Instagram's wordmark SVG only exists on pages this app steers away
      // from (ranked home, login). Cache it whenever it's seen so the
      // Following feed's header can show it too.
      var WORDMARK_KEY = 'insta-no-reels-wordmark';
      function cacheWordmark() {
        var svg = document.querySelector('svg[aria-label="Instagram"]');
        if (!svg) return;
        try {
          if (!localStorage.getItem(WORDMARK_KEY)) localStorage.setItem(WORDMARK_KEY, svg.outerHTML);
        } catch (e) {}
      }

      function wordmarkElement() {
        var cached = null;
        try { cached = localStorage.getItem(WORDMARK_KEY); } catch (e) {}
        if (cached) {
          try {
            var parsed = new DOMParser().parseFromString(cached, 'image/svg+xml').documentElement;
            if (parsed && parsed.tagName === 'svg') {
              var svg = document.importNode(parsed, true);
              svg.removeAttribute('width');
              svg.setAttribute('height', '26');
              svg.style.cssText = 'display:block;height:26px;width:auto;color:inherit;';
              return svg;
            }
          } catch (e) {}
        }
        var text = document.createElement('span');
        text.textContent = 'Instagram';
        text.style.cssText = 'font-size:22px;font-weight:600;letter-spacing:-0.3px;line-height:1;white-space:nowrap;';
        return text;
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

        var height = Math.max(row.getBoundingClientRect().height, 44);
        row.setAttribute('data-insta-no-reels-header', 'done');
        if (flags.headerScrollsAway) unstickHeader(header);
        row.style.setProperty('position', 'relative', 'important');
        row.style.setProperty('min-height', height + 'px', 'important');

        var logoWrap = clickableFor(logo);

        // On the Following feed the title is the text "Following". Show
        // the Instagram wordmark there instead: the real SVG if it has
        // been cached from a page that renders it, else a text title.
        if (logo.tagName !== 'svg') {
          var title = wordmarkElement();
          title.setAttribute('data-insta-no-reels-title', 'true');
          title.style.cssText += ';position:absolute;top:50%;left:50%;transform:translate(-50%,-50%);cursor:pointer;';
          title.addEventListener('click', function (event) {
            event.preventDefault();
            event.stopPropagation();
            postNative({ type: 'switchAccounts' });
          });
          row.appendChild(title);
          logoWrap.style.setProperty('visibility', 'hidden', 'important');
        }

        // Identify the row's icons. Labels are matched loosely, and any
        // unlabelled leftovers are taken in DOM order (create comes before
        // notifications in Instagram's markup). The Following feed's back
        // arrow is hidden: it only leads to the ranked feed we redirect
        // away from anyway.
        var create = null;
        var notifications = null;
        var leftovers = [];
        row.querySelectorAll('svg').forEach(function (svg) {
          if (logoWrap.contains(svg)) return;
          var label = (svg.getAttribute('aria-label') || '').toLowerCase();
          if (label.indexOf('chevron') !== -1) return;
          if (label === 'back' || label.indexOf('back') === 0) {
            hide(clickableFor(svg));
            return;
          }
          if (label.indexOf('notification') !== -1 || label.indexOf('activity') !== -1) {
            notifications = notifications || svg;
          } else if (label.indexOf('new') !== -1 || label.indexOf('create') !== -1 || label.indexOf('post') !== -1) {
            create = create || svg;
          } else {
            leftovers.push(svg);
          }
        });
        if (!create && leftovers.length) create = leftovers.shift();
        if (!notifications && leftovers.length) notifications = leftovers.shift();

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
      // as, so the switcher can label it. Instagram's session cookie
      // carries the user id; its user-info endpoint maps that to the
      // username. Nothing is read from the page's markup, so it can't
      // pick up someone else's link by mistake.
      var usernameReported = false;
      var usernameRetryAt = 0;
      function reportUsername() {
        if (usernameReported || Date.now() < usernameRetryAt) return;
        var match = /(?:^|;\s*)ds_user_id=(\d+)/.exec(document.cookie || '');
        if (!match) return; // not logged in yet
        usernameReported = true;
        igFetch('/api/v1/users/' + match[1] + '/info/').then(function (json) {
          var username = json && json.user && json.user.username;
          if (username) {
            postNative({ type: 'username', value: username });
            ownProfile = { username: username, pic: json.user.profile_pic_url || '' };
            // Rebuild the story row so "Your story" leads it.
            storiesTrayFetchedAt = 0;
            scheduleSweep();
          } else {
            usernameReported = false;
            usernameRetryAt = Date.now() + 60 * 1000;
          }
        }).catch(function () {
          usernameReported = false;
          usernameRetryAt = Date.now() + 60 * 1000;
        });
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

      // Instagram's web app id, sent by the site itself on its internal
      // API calls; the endpoints reject requests without it.
      var IG_APP_ID = '936619743392459';
      function igFetch(path) {
        return fetch(path, {
          credentials: 'include',
          headers: { 'x-ig-app-id': IG_APP_ID, 'x-requested-with': 'XMLHttpRequest', 'accept': 'application/json' }
        }).then(function (response) {
          return response.ok ? response.json() : null;
        });
      }

      function onFollowingFeed() {
        return location.pathname === '/' && /[?&]variant=following/.test(location.search);
      }

      // Instagram only renders the story tray on the ranked home, not on
      // the Following feed. So on the Following feed we build our own from
      // the same internal endpoint the site uses for the tray: a row of
      // avatars (gradient ring = unseen, grey = seen), each opening that
      // person's story.
      var STORIES_TRAY_MARK = 'data-insta-no-reels-tray';
      var storiesTray = null;
      var storiesTrayFetchedAt = 0;
      var storiesTrayLoading = false;
      var storiesTrayRetryAt = 0;

      // Sized to match Instagram's own tray on the ranked feed: 76px rings
      // (2px ring, 3px gap, 66px avatar), ~101px between item centres,
      // 13px labels, 14px above / 12px below, first avatar 20px in.
      var ownProfile = null; // { username, pic } once the user-info lookup completes

      function isDarkTheme() {
        var match = /rgba?\((\d+),\s*(\d+),\s*(\d+)/.exec(getComputedStyle(document.body).backgroundColor || '');
        if (!match) return true;
        return (0.299 * match[1] + 0.587 * match[2] + 0.114 * match[3]) < 128;
      }

      function buildStoriesTray(items) {
        var dark = isDarkTheme();
        var pageBackground = getComputedStyle(document.body).backgroundColor || (dark ? '#000' : '#fff');
        var seenRing = dark ? '#3f3f3f' : '#dbdbdb';
        var unseenRing = 'linear-gradient(45deg,#f09433,#e6683c,#dc2743,#cc2366,#bc1888)';

        var tray = document.createElement('div');
        tray.setAttribute(STORIES_TRAY_MARK, 'true');
        tray.style.cssText = 'display:flex;gap:23px;overflow-x:auto;padding:14px 20px 12px;-webkit-overflow-scrolling:touch;scrollbar-width:none;';

        function makeItem(options) {
          var link = document.createElement('a');
          link.href = options.href;
          link.style.cssText = 'flex:0 0 auto;width:78px;text-align:center;text-decoration:none;color:inherit;';

          var ring = document.createElement('div');
          ring.style.cssText = 'position:relative;width:76px;height:76px;margin:0 auto;border-radius:50%;padding:2px;box-sizing:border-box;background:' + options.ring + ';';

          var avatar = document.createElement('img');
          avatar.src = options.pic || '';
          avatar.alt = '';
          avatar.style.cssText = 'width:100%;height:100%;border-radius:50%;border:3px solid ' + pageBackground + ';box-sizing:border-box;object-fit:cover;display:block;';
          ring.appendChild(avatar);

          if (options.plusBadge) {
            var badge = document.createElement('div');
            badge.textContent = '+';
            badge.style.cssText = 'position:absolute;right:-1px;bottom:-1px;width:22px;height:22px;border-radius:50%;box-sizing:border-box;' +
              'background:' + (dark ? '#fff' : '#0095f6') + ';color:' + (dark ? '#000' : '#fff') + ';border:2px solid ' + pageBackground + ';' +
              'font-size:18px;line-height:18px;font-weight:600;text-align:center;';
            ring.appendChild(badge);
          }

          var name = document.createElement('div');
          name.textContent = options.label;
          name.style.cssText = 'font-size:13px;margin-top:8px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;opacity:' + (options.muted ? '0.6' : '0.9') + ';';

          link.appendChild(ring);
          link.appendChild(name);
          if (options.onClick) {
            link.addEventListener('click', function (event) {
              event.preventDefault();
              options.onClick();
            });
          }
          return link;
        }

        var rest = [];
        var own = null;
        items.forEach(function (item) {
          var user = item && item.user;
          if (!user || !user.username) return;
          if (ownProfile && user.username === ownProfile.username) own = item;
          else rest.push(item);
        });

        // Everything the in-app viewer needs, in row order, plus each
        // person's ring so it can be greyed once their story is watched.
        var viewerReels = [];
        var storyRings = {};
        function reelFor(item) {
          return {
            userPk: item.user.pk || item.id,
            username: item.user.username,
            pic: item.user.profile_pic_url || '',
            seen: !!(item.seen && item.latest_reel_media && item.seen >= item.latest_reel_media)
          };
        }
        function openAt(index, fallbackHref) {
          var viewer = window.__instaNoReelsViewer;
          var opened = viewer && viewer.open(viewerReels, index, function (username) {
            var ring = storyRings[username];
            if (ring) ring.style.background = seenRing;
          });
          if (!opened) window.location.assign(fallbackHref);
        }

        // "Your story" first: the user's own story if they have one, else
        // a + badge that opens Instagram's create flow (the header's +).
        if (ownProfile) {
          if (own) {
            viewerReels.push(reelFor(own));
            var ownIndex = viewerReels.length - 1;
            var ownHref = '/stories/' + ownProfile.username + '/';
            var ownLink = makeItem({ href: ownHref, pic: ownProfile.pic, ring: seenRing, label: 'Your story', muted: true, onClick: function () { openAt(ownIndex, ownHref); } });
            storyRings[ownProfile.username] = ownLink.firstChild;
            tray.appendChild(ownLink);
          } else {
            tray.appendChild(makeItem({
              href: '#', pic: ownProfile.pic, ring: 'transparent', label: 'Your story', muted: true, plusBadge: true,
              onClick: function () {
                var create = document.querySelector('header svg[aria-label="New post"], header svg[aria-label="Create"]');
                var button = create ? clickableFor(create) : null;
                if (button) button.click();
              }
            }));
          }
        }

        rest.forEach(function (item) {
          var user = item.user;
          var reel = reelFor(item);
          viewerReels.push(reel);
          var index = viewerReels.length - 1;
          var href = '/stories/' + user.username + '/';
          var link = makeItem({ href: href, pic: user.profile_pic_url, ring: reel.seen ? seenRing : unseenRing, label: user.username, onClick: function () { openAt(index, href); } });
          storyRings[user.username] = link.firstChild;
          tray.appendChild(link);
        });

        // Order for the direct-URL fallback chaining in bootstrap.
        try {
          sessionStorage.setItem('insta-no-reels-story-order', JSON.stringify(rest.map(function (item) { return item.user.username; })));
        } catch (e) {}
        return tray;
      }

      // A direct /stories/<user>/ load shows a confirmation ("View story" /
      // "view as @you") before playing. Confirm it automatically, once per
      // page, so the story just starts.
      var storyViewConfirmedFor = '';
      function autoConfirmStory() {
        if (!inStories() || storyViewConfirmedFor === location.pathname) return;
        var controls = document.querySelectorAll('button, [role="button"], a');
        for (var i = 0; i < controls.length; i++) {
          var text = (controls[i].textContent || '').trim();
          if (/^view( story| as)/i.test(text)) {
            storyViewConfirmedFor = location.pathname;
            controls[i].click();
            return;
          }
        }
      }

      function loadStoriesTray() {
        var now = Date.now();
        if (storiesTrayLoading || now < storiesTrayRetryAt) return;
        if (storiesTray && now - storiesTrayFetchedAt < 5 * 60 * 1000) return;
        storiesTrayLoading = true;
        igFetch('/api/v1/feed/reels_tray/').then(function (json) {
          storiesTrayLoading = false;
          var items = json && Array.isArray(json.tray) ? json.tray : null;
          if (!items) {
            storiesTrayRetryAt = Date.now() + 60 * 1000;
            return;
          }
          var fresh = buildStoriesTray(items);
          if (storiesTray && storiesTray.parentElement) {
            storiesTray.parentElement.replaceChild(fresh, storiesTray);
          }
          storiesTray = fresh;
          storiesTrayFetchedAt = Date.now();
          scheduleSweep();
        }).catch(function () {
          storiesTrayLoading = false;
          storiesTrayRetryAt = Date.now() + 60 * 1000;
        });
      }

      function instagramTrayPresent() {
        var links = document.querySelectorAll('a[href^="/stories/"]');
        for (var i = 0; i < links.length; i++) {
          if (!links[i].closest('[' + STORIES_TRAY_MARK + ']')) return true;
        }
        return false;
      }

      function sweepStoriesTray() {
        if (!onFollowingFeed()) return;
        // Only stand in when Instagram's own tray isn't on the page.
        if (instagramTrayPresent()) {
          if (storiesTray && storiesTray.isConnected) storiesTray.remove();
          return;
        }
        loadStoriesTray();
        if (!storiesTray || storiesTray.isConnected || !storiesTray.childElementCount) return;
        // Re-inserting while scrolled down would shift the content under
        // the thumb; wait until the user is back near the top.
        if ((window.scrollY || document.documentElement.scrollTop || 0) > 200) return;

        var firstLike = document.querySelector('svg[aria-label="Like"], svg[aria-label="Unlike"]');
        if (!firstLike) return;
        var entry = feedItemFor(firstLike) || ancestor(firstLike, 6);
        // Climb through wrappers holding only this post, up to the list
        // of posts itself.
        while (entry.parentElement && !isPageChrome(entry.parentElement) &&
               likeCount(entry.parentElement) === likeCount(entry)) {
          entry = entry.parentElement;
        }
        var list = entry.parentElement;
        if (list && !isPageChrome(list) && list.parentElement && likeCount(list) > likeCount(entry)) {
          // Just above the list, outside it: Instagram's re-renders of
          // the list can't remove it, so it never jumps.
          list.parentElement.insertBefore(storiesTray, list);
        } else if (entry.parentElement) {
          entry.parentElement.insertBefore(storiesTray, entry);
        }
      }

      // The inbox's back arrow would route to the ranked feed; send it
      // to the Following feed instead. Only on the inbox itself — inside a
      // thread, back should still return to the inbox.
      function hookInboxBack() {
        if (location.pathname !== '/direct/inbox/' && location.pathname !== '/direct/') return;
        document.querySelectorAll('svg[aria-label="Back"]').forEach(function (svg) {
          var button = clickableFor(svg);
          if (!button || button.getAttribute('data-insta-no-reels-inbox-back')) return;
          button.setAttribute('data-insta-no-reels-inbox-back', 'true');
          button.addEventListener('click', function (event) {
            event.preventDefault();
            event.stopPropagation();
            event.stopImmediatePropagation();
            window.location.assign(HOME_PATH);
          }, true);
        });
      }

      // ---- Messages: the Notes row --------------------------------
      // Instagram keeps the row of notes pinned above the conversation
      // list. Two cases: it's `sticky` (put it back in the flow so it
      // scrolls away), or the list scrolls in its own container beneath
      // it (collapse the row once the list has been scrolled, restore it
      // at the top).
      var inboxNotes = null;
      var inboxNotesMode = '';
      var inboxNotesHeight = 0;
      var inboxNotesCollapsed = false;

      function inInbox() {
        return location.pathname.indexOf('/direct/') === 0;
      }

      // The full-width, horizontally scrolling row that holds "Your note".
      function findInboxNotes() {
        var label = labelledElements(['Your note'], document.body)[0];
        if (!label) return null;
        var node = label;
        for (var i = 0; i < 10 && node.parentElement && node.parentElement !== document.body; i++) {
          var rect = node.getBoundingClientRect();
          if (rect.width >= window.innerWidth * 0.9 && rect.height > 0 && rect.height <= 320) return node;
          node = node.parentElement;
        }
        return null;
      }

      function sweepInboxNotes() {
        if (!inInbox()) {
          inboxNotes = null;
          return;
        }
        if (inboxNotes && inboxNotes.isConnected) return;
        var notes = findInboxNotes();
        if (!notes) return;
        inboxNotes = notes;
        inboxNotesHeight = notes.getBoundingClientRect().height;
        inboxNotesCollapsed = false;

        var node = notes;
        for (var i = 0; i < 6 && node && node !== document.body; i++) {
          if (getComputedStyle(node).position === 'sticky' && node.getBoundingClientRect().height <= 320) {
            node.style.setProperty('position', 'relative', 'important');
            inboxNotesMode = 'flow';
            return;
          }
          node = node.parentElement;
        }

        inboxNotesMode = 'collapse';
        // Collapse the tight wrapper around the row rather than the row
        // itself: the left/right scroll arrows are overlaid siblings
        // inside it, and they'd otherwise stay behind. Stops before any
        // wrapper that also holds the search box or grows beyond the row.
        var block = notes;
        while (block.parentElement && !isPageChrome(block.parentElement) &&
               !block.parentElement.querySelector('input') &&
               block.parentElement.getBoundingClientRect().height <= inboxNotesHeight + 40) {
          block = block.parentElement;
        }
        inboxNotesBlock = block;
        block.style.setProperty('max-height', (inboxNotesHeight + 40) + 'px', 'important');
        block.style.setProperty('transition', 'max-height 0.2s ease, opacity 0.2s ease', 'important');
      }

      var inboxNotesBlock = null;
      function setInboxNotesCollapsed(collapsed) {
        if (!inboxNotesBlock || inboxNotesMode !== 'collapse' || collapsed === inboxNotesCollapsed) return;
        inboxNotesCollapsed = collapsed;
        inboxNotesBlock.style.setProperty('max-height', collapsed ? '0px' : (inboxNotesHeight + 40) + 'px', 'important');
        inboxNotesBlock.style.setProperty('opacity', collapsed ? '0' : '1', 'important');
        // Invisible arrows must not stay tappable.
        inboxNotesBlock.style.setProperty('visibility', collapsed ? 'hidden' : 'visible', 'important');
        inboxNotesBlock.style.setProperty('pointer-events', collapsed ? 'none' : 'auto', 'important');
      }

      function onInboxScroll(event) {
        if (!inInbox() || !inboxNotes) return;
        var target = event.target;
        var scroller = (target && target !== document && target.scrollTop !== undefined) ? target : null;
        if (scroller && scroller.contains(inboxNotes)) return; // already scrolls with the list
        var y = scroller ? scroller.scrollTop : (window.scrollY || 0);
        setInboxNotesCollapsed(y > 24);
      }

      // ---- Never show the ranked home ------------------------------
      // Instagram's router can land on the ranked feed through in-app
      // navigation (e.g. the story viewer's X) without a real page load,
      // leaving the URL claiming "following" while the ranked page is
      // rendered. Instagram only renders its own story tray on that page,
      // so its presence at "/" is the tell — reload the Following feed.
      var RANKED_REDIRECT_KEY = 'insta-no-reels-ranked-redirects';
      function rankedRedirectAllowed() {
        var now = Date.now();
        var recent = [];
        try { recent = JSON.parse(sessionStorage.getItem(RANKED_REDIRECT_KEY) || '[]'); } catch (e) {}
        recent = recent.filter(function (t) { return now - t < 15000; });
        if (recent.length >= 2) return false; // something's looping; give up quietly
        recent.push(now);
        try { sessionStorage.setItem(RANKED_REDIRECT_KEY, JSON.stringify(recent)); } catch (e) {}
        return true;
      }

      // Only fires on the *settled* ranked page: never during the first
      // seconds of a load (Instagram can briefly render the ranked layout
      // while the Following page hydrates, and a reload there would just
      // stack page loads), never while the header carries the Following
      // title, and only after the tray has been present on two checks at
      // least a second apart.
      var rankedRedirecting = false;
      var rankedTraySeenAt = 0;
      function followingTitlePresent() {
        var headers = document.querySelectorAll('header');
        for (var i = 0; i < headers.length; i++) {
          if (labelledElements(['Following'], headers[i]).length) return true;
        }
        return false;
      }
      function sweepRankedHome() {
        if (rankedRedirecting || location.pathname !== '/' || inStories()) return;
        if (performance.now() < 4000) return;
        if (!instagramTrayPresent() || followingTitlePresent()) {
          rankedTraySeenAt = 0;
          return;
        }
        var now = Date.now();
        if (!rankedTraySeenAt) {
          rankedTraySeenAt = now;
          return;
        }
        if (now - rankedTraySeenAt < 1000) return;
        if (!rankedRedirectAllowed()) return;
        rankedRedirecting = true;
        window.location.replace(HOME_PATH);
      }

      // The story viewer's X: when the story was opened from the app's
      // story row (a real navigation to /stories/...), closing it should
      // return to the Following feed, not Instagram's ranked home.
      function hookStoryClose() {
        if (!inStories()) return;
        document.querySelectorAll('svg[aria-label="Close"]').forEach(function (svg) {
          var button = clickableFor(svg);
          if (!button || button.getAttribute('data-insta-no-reels-close')) return;
          button.setAttribute('data-insta-no-reels-close', 'true');
          button.addEventListener('click', function (event) {
            event.preventDefault();
            event.stopPropagation();
            event.stopImmediatePropagation();
            window.location.assign(HOME_PATH);
          }, true);
        });
      }

      var sweepQueued = false;
      var sweepDeferredSince = 0;
      var lastScrollAt = 0;
      function scheduleSweep() {
        if (sweepQueued) return;
        sweepQueued = true;
        // Coalesce bursts of DOM mutations (Instagram fires a lot while
        // scrolling) into one pass every ~150ms — and while the user is
        // actively scrolling, hold the pass until the scroll settles (up
        // to 600ms), so the work doesn't land mid-gesture.
        setTimeout(function () {
          sweepQueued = false;
          var now = Date.now();
          if (now - lastScrollAt < 120) {
            if (!sweepDeferredSince) sweepDeferredSince = now;
            if (now - sweepDeferredSince < 600) {
              scheduleSweep();
              return;
            }
          }
          sweepDeferredSince = 0;
          labelIndex = null;
          sweepSponsored();
          sweepSuggested();
          sweepFeedReels();
          sweepStoryAds();
          sweepNavIcons();
          sweepSearchPage();
          activateSearch();
          hookSearchCancel();
          sweepAppBanners();
          cacheWordmark();
          styleHeader();
          hookInboxBack();
          sweepRankedHome();
          hookStoryClose();
          autoConfirmStory();
          sweepStoriesTray();
          sweepInboxNotes();
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
        document.addEventListener('scroll', function () {
          lastScrollAt = Date.now();
          schedulePostCounter();
        }, { capture: true, passive: true });
        document.addEventListener('scroll', onInboxScroll, { capture: true, passive: true });
        // A playing story ad doesn't necessarily mutate the DOM, so poll
        // for it too (cheap: returns immediately outside the story viewer).
        // Same for the search page, whose focus state may need a nudge
        // after the page settles.
        setInterval(function () {
          labelIndex = null;
          sweepStoryAds();
          activateSearch();
          sweepRankedHome();
          autoConfirmStory();
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
