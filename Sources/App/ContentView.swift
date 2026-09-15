import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var deepLinks: DeepLinkRouter

    @StateObject private var state = WebViewState()
    @StateObject private var accounts = AccountStore()
    @StateObject private var usage = UsageTracker()

    var body: some View {
        ZStack {
            // Solid strip behind the status bar. Instagram's mobile site
            // follows the system light/dark setting, so this matches it.
            Color(uiColor: .systemBackground)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                UsageBar(usage: usage)

                // Only extend under the bottom (home indicator). Extending
                // under the top let posts scroll past above Instagram's
                // sticky header, visible through the status bar area.
                //
                // Keyed on the account id so switching accounts rebuilds
                // the web view on that account's own data store.
                InstagramWebView(
                    state: state,
                    account: accounts.current,
                    accountStore: accounts,
                    usage: usage,
                    deepLinks: deepLinks
                )
                .id(accounts.current.id)
                .ignoresSafeArea(edges: .bottom)
            }

            // Covers the blank/white page while instagram.com does its
            // first load, so launch feels like a native app instead of a
            // browser tab spinning up.
            if !state.hasLoadedOnce {
                SplashView()
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.3), value: state.hasLoadedOnce)
        .onAppear { handleScenePhase(scenePhase) }
        .onChange(of: scenePhase) { _, phase in
            handleScenePhase(phase)
        }
        .onChange(of: accounts.currentID) { _, accountID in
            // DM checks follow the account that's on screen.
            if scenePhase == .active {
                InboxChecker.shared.startForegroundPolling(accountID: accountID)
            }
        }
        .confirmationDialog("Switch account", isPresented: $accounts.isPickerPresented, titleVisibility: .visible) {
            ForEach(accounts.accounts) { account in
                let name = accounts.displayName(for: account)
                Button(account.id == accounts.currentID ? "\(name) ✓" : name) {
                    guard account.id != accounts.currentID else { return }
                    switchAccount { accounts.switchTo(account) }
                }
            }

            Button("Add account…") {
                switchAccount { accounts.addAccount() }
            }

            if accounts.accounts.count > 1 {
                Button("Remove this account", role: .destructive) {
                    switchAccount { accounts.removeCurrent() }
                }
            }

            Button("Cancel", role: .cancel) {}
        }
    }

    private func handleScenePhase(_ phase: ScenePhase) {
        usage.setActive(phase == .active)
        switch phase {
        case .active:
            InboxChecker.shared.startForegroundPolling(accountID: accounts.currentID)
        case .background:
            InboxChecker.shared.stopForegroundPolling()
            AppDelegate.scheduleInboxRefresh()
        default:
            InboxChecker.shared.stopForegroundPolling()
        }
    }

    /// Show the splash again while the new account's web view loads.
    private func switchAccount(_ change: () -> Void) {
        state.hasLoadedOnce = false
        change()
    }
}

/// "⏱ 0:07 · 1 post" strip between the status bar and Instagram's header.
private struct UsageBar: View {
    @ObservedObject var usage: UsageTracker

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "timer")
            Text(usage.elapsedText)
                .monospacedDigit()
            Text("·")
            Text(usage.postsText)
                .foregroundStyle(usage.isOverPostsThreshold ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color(uiColor: .systemBackground))
    }
}

private struct SplashView: View {
    var body: some View {
        ZStack {
            Color("LaunchBackground")
                .ignoresSafeArea()

            VStack(spacing: 24) {
                Image("SplashLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 96, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))

                ProgressView()
            }
        }
    }
}
