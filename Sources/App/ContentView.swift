import SwiftUI

struct ContentView: View {
    @StateObject private var state = WebViewState()

    var body: some View {
        ZStack {
            InstagramWebView(state: state)
                .ignoresSafeArea()

            // Covers the blank/white page while instagram.com does its
            // first load, so launch feels like a native app instead of a
            // browser tab spinning up.
            if !state.hasLoadedOnce {
                SplashView()
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.3), value: state.hasLoadedOnce)
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
