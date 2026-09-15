# InstaNoReels

A personal, Socialite-style iOS wrapper around instagram.com. It logs into
your real Instagram account through a `WKWebView` (so all normal Instagram
functionality — posting, DMs, stories, notifications — works), while
stripping out:

- The **Reels tab** (blocked at both the native-navigation level and the
  in-app SPA-navigation level, so tapping it or swiping to it does nothing)
- **Reels-style videos mixed into your main feed** (toggle in `AppConfig.swift`)
- **Sponsored posts (ads)** in the feed
- **"Suggested for you" / "Suggested Posts"** in the feed
- The **Explore page** entirely (also blocked at both levels)
- **Non-account search results** — search only ever returns accounts, never
  hashtags, places, or Reels
- **"Open app" / "Get the app" nags** from the mobile site, plus the
  `instagram://` and App Store hand-off links behind them
- **Story ads** — these can't be blocked (Instagram serves them inline in
  the story sequence), so the app auto-skips past any story labelled
  "Sponsored" the moment it appears

Search stays: on the mobile layout the nav's search icon is Instagram's
Explore link, so it's rerouted to Instagram's own search page
(`/explore/search/`) — the only `/explore/*` route allowed through — and
results are filtered to accounts. The page is put straight into
Instagram's search-focused state (Recent list), its suggestion grid is
hidden as a fallback, and "Cancel" goes to the home feed, so the grid of
recommended reels is never reachable.

A usage strip above Instagram's header shows how long the app has been in
the foreground this session and how many feed posts have scrolled past
(ads and suggested posts don't count). Being in the background for 30+
minutes starts a fresh session.

It also smooths over the usual web-view tells so it feels like a native
app: a proper icon and launch screen, a native splash while the first page
loads, pull-to-refresh with haptics, and no pinch-zoom, text-selection
handles, or long-press link previews.

The feed header is rearranged Socialite-style — "+" on the left, the
wordmark centered, notifications on the right — and tapping the wordmark
opens a **native account switcher** instead of Instagram's Following /
Favorites picker. Each account lives in its own isolated cookie store
(`WKWebsiteDataStore(forIdentifier:)`, hence the iOS 17 minimum), so
"Add account" lands on a fresh login page and switching is instant with
no re-login. Accounts are labelled with their username once the page
reports it.

This is for your own personal use on your own account. It can't be published
to the App Store (it strips Instagram features against Meta's Terms of
Service, which Apple's review would reject), so everything below is about
building and installing it for yourself only.

## How the filtering works (and what to do when Instagram changes something)

Instagram's web app uses obfuscated, frequently-changing CSS class names, so
the filtering deliberately avoids them and keys off things Instagram is
unlikely to change:

- `href` paths (`/reels/`, `/explore/`, `/reel/...`)
- `aria-label`s (accessibility labels — "Reels", "Explore")
- Visible text ("Sponsored", "Suggested for you")
- The shape of Instagram's internal search JSON responses

All of this logic lives in two files:

- [`Sources/WebView/ContentFilterScript.swift`](Sources/WebView/ContentFilterScript.swift) —
  the actual JavaScript injected into the page. `bootstrap` blocks SPA
  navigation and filters search JSON; `cleanup` hides nav icons and sweeps
  posts for ads/suggested content.
- [`Sources/WebView/InstagramWebView.swift`](Sources/WebView/InstagramWebView.swift) —
  the native side: blocks real navigations to `/reels` and `/explore`.

If Instagram ships a redesign and something stops being hidden (e.g. a new
"Suggested" label wording, or Reels tab gets a new URL), open Safari's Web
Inspector against the app (Mac + Xcode: Develop menu → your device → the
page) to find the new `href`/`aria-label`/text, then tweak the selectors in
`ContentFilterScript.swift` accordingly. The search-filtering (`keepAccountsOnly`)
is the most likely thing to need adjusting if Instagram changes its internal
API's JSON field names — inspect the Network tab for a request to
`web/search/topsearch` while typing in search to see the current shape.

Config toggles live in [`Sources/WebView/AppConfig.swift`](Sources/WebView/AppConfig.swift):
mobile vs. desktop user-agent, and whether to hide Reels-format videos inside
the regular feed.

## What you need

- A Windows PC (what you're building from) with Apple's iTunes installed
  (needed for USB drivers during the one-time SideStore pairing)
- A free GitHub account (to run the build for free in the cloud — no Mac
  needed)
- A free Apple ID (no paid Developer Program required)
- Your iPhone + a USB cable (only for the initial pairing)

## Step-by-step: from this code to the app on your phone

### 1. Push this repo to GitHub

GitHub Actions needs the code hosted on GitHub to run the build. If you
haven't already:

```bash
git add -A
git commit -m "Initial InstaNoReels iOS app"
```

Then create a new (private, recommended) repo on GitHub and push:

```bash
git remote add origin https://github.com/<your-username>/insta_no_reels.git
git branch -M main
git push -u origin main
```

(I can run these commands for you if you'd like — just say so. I won't push
to GitHub without you confirming, since that publishes the code.)

### 2. Let GitHub Actions build the unsigned .ipa

Pushing to `main` automatically triggers the workflow at
[`.github/workflows/build-ipa.yml`](.github/workflows/build-ipa.yml). To
check progress or re-run it manually:

1. Go to your repo on GitHub → **Actions** tab
2. You'll see a run of "Build unsigned IPA" — click it, wait ~3-5 minutes
   for it to go green
3. If you ever want to rebuild without pushing new code, click **Run
   workflow** on that same page

### 3. Download the .ipa

Once the run finishes, scroll to the bottom of that run's page to
**Artifacts** and download `InstaNoReels-unsigned` (a zip containing
`InstaNoReels.ipa`). Unzip it to get the `.ipa` file.

### 4. Install SideStore (one-time setup)

SideStore is what handles auto-refreshing the app's signing for you, so you
never have to manually re-sign every 7 days. It installs in two parts —
follow the **official current instructions** at
[sidestore.io](https://sidestore.io/#/getting-started), since the exact
steps shift as the project updates. The general shape of it:

1. Install SideStore's pairing helper on your Windows PC (their docs call
   this "SideServer" / "AltServer", depending on current version) — it's
   what talks to your phone over USB the first time and over WiFi after that
2. Plug your iPhone in via USB, unlock it, trust the computer if prompted
3. Use the helper to install the **SideStore app itself** onto your iPhone
   (this is a one-time sideload of SideStore, done the same way any
   free-signed app is — the helper handles it)
4. On your iPhone, open **Settings → General → VPN & Device Management**,
   trust the developer certificate for SideStore
5. Follow SideStore's docs to complete "pairing" your phone with your PC —
   this is what lets it refresh signing over WiFi later without a cable

### 5. Install InstaNoReels through SideStore

1. Open the **SideStore** app on your iPhone
2. Use its "install from file" / import option to install `InstaNoReels.ipa`
   (transfer it to your phone first — e.g. AirDrop alternative like sending
   it to yourself, saving it to Files via a cloud drive, or SideStore's own
   USB-transfer option; check their docs for the current easiest method)
3. SideStore signs it with your Apple ID (same as Sideloadly would) and
   installs it

### 6. Trust the app on your iPhone

1. On your iPhone: **Settings → General → VPN & Device Management**
2. Under "Developer App", tap your Apple ID email
3. Tap **Trust**

### 7. Launch it and log in

Open **InstaNoReels** from your home screen and log into your Instagram
account as normal — it behaves like logging into instagram.com in Safari,
just without Reels, ads, suggested posts, or Explore.

### 8. Auto-refresh — nothing to do manually

SideStore refreshes the app's signing on the phone itself (via its local
VPN tunnel and the pairing file) — no PC involved after the one-time setup.
Keep SideStore's VPN toggle on, and open the SideStore app now and then:
the My Apps tab shows days-until-expiry for each app, and opening the app
also triggers a refresh on demand. If it ever reports the pairing file has
lapsed (e.g. after restoring the phone), redo the pairing step above.

## Making code changes later

If you edit anything in `Sources/`, just commit and push to `main` —
GitHub Actions rebuilds automatically. Download the new `.ipa` from the
Actions run's Artifacts and re-install it through SideStore (step 5) — the
one-time setup in steps 4 doesn't need repeating.

## Limitations / things to know

- This is a best-effort client-side filter, not a security boundary — if
  Instagram redesigns a page, some things may briefly slip through until
  the selectors are updated (see above)
- Camera/microphone/photo-library permissions are wired up for posting
  photos/videos and stories
- This only works for the account(s) you log into on your own device — it's
  not something you distribute to other people (both because Apple won't
  allow it on the App Store, and because it relies on your own personal
  Apple ID signing)
