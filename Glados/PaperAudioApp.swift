import SwiftUI

let appGroupID = "group.com.borr.scifm"
let urlDefaultsKey = "pendingArticleURL"

@main
struct SciFMApp: App {
    @StateObject private var playerViewModel = PlayerViewModel()
    @State private var incomingURL: URL? = nil
    @State private var selectedTab = 0
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            TabView(selection: $selectedTab) {
                PlayerView(incomingURL: $incomingURL)
                    .tabItem { Label("Library", systemImage: "books.vertical") }
                    .tag(0)

                ReviewsView(selectedTab: $selectedTab)
                    .tabItem { Label("Reviews", systemImage: "text.book.closed") }
                    .tag(1)

                PrimaryView(selectedTab: $selectedTab)
                    .tabItem { Label("Papers", systemImage: "doc.text.magnifyingglass") }
                    .tag(3)

                DiscoverView(selectedTab: $selectedTab)
                    .tabItem { Label("Articles", systemImage: "newspaper") }
                    .tag(2)

                PlaylistsView(selectedTab: $selectedTab)
                    .tabItem { Label("Radio", systemImage: "dot.radiowaves.left.and.right") }
                    .tag(5)
            }
            .environmentObject(playerViewModel)
            .preferredColorScheme(.dark)
            .overlay { LandscapeArtworkOverlay() }
            .fullScreenCover(isPresented: $playerViewModel.showSeminar) {
                SeminarCover()
                    .environmentObject(playerViewModel)
                    .preferredColorScheme(.dark)
            }
            .fullScreenCover(isPresented: $playerViewModel.showDebug) {
                SeminarDebugView()
                    .environmentObject(playerViewModel)
                    .preferredColorScheme(.dark)
            }
            .onOpenURL { url in handleDeepLink(url) }
            .onAppear {
                AppSettings.migrateToHaikuPolishingIfNeeded()
                checkPendingURL()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                checkPendingURL()
            }
        }
    }

    private func handleDeepLink(_ url: URL) {
        guard url.scheme == "scifm",
              url.host == "open",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let urlParam = components.queryItems?.first(where: { $0.name == "url" })?.value,
              let articleURL = URL(string: urlParam)
        else { return }
        incomingURL = articleURL
        selectedTab = 0
    }

    private func checkPendingURL() {
        guard let defaults = UserDefaults(suiteName: appGroupID),
              let urlString = defaults.string(forKey: urlDefaultsKey),
              let url = URL(string: urlString)
        else { return }
        defaults.removeObject(forKey: urlDefaultsKey)
        defaults.synchronize()
        incomingURL = url
        selectedTab = 0
    }
}
