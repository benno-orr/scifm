import SwiftUI

// MARK: - Playlists tab
//
// A Spotify-style view over the Commentaries feed: one continuous TTS playlist.
// The default playlist is "All" (every commentary in the feed); tapping play
// streams them back to back via `PlaylistPlayer`. Tap any track to start there.

struct PlaylistsView: View {
    @Binding var selectedTab: Int
    @ObservedObject private var player = PlaylistPlayer.shared

    @State private var articles: [FeedArticle] = []
    @State private var isLoading = false
    @State private var loadError = false
    /// Scraped artwork for the track currently playing.
    @State private var artworkURL: URL? = nil

    /// Default playlist: the recent editorials/commentaries scraped from the web
    /// (the same feed as the Comms tab).
    private let playlistName = "Recent"

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                Group {
                    if isLoading && articles.isEmpty {
                        ProgressView("Loading editorials…")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if loadError && articles.isEmpty {
                        emptyError
                    } else {
                        list
                    }
                }
                if player.isActive { nowPlayingBar }
            }
            .charcoalBackdrop()
            .navigationTitle("Playlists")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if isLoading {
                        ProgressView().scaleEffect(0.8)
                    } else {
                        Button { Task { await load() } } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                }
            }
            .onAppear { if articles.isEmpty { Task { await load() } } }
            .refreshable { await load() }
        }
    }

    // MARK: Track list

    private var list: some View {
        List {
            Section {
                headerCard
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 12, trailing: 12))
                    .listRowBackground(Color.clear)
            }
            Section {
                ForEach(Array(articles.enumerated()), id: \.element.id) { idx, article in
                    trackRow(index: idx, article: article)
                        .listRowBackground(Color.rowTranslucent)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            player.play(playlist: playlistName, articles: articles, startAt: idx)
                        }
                }
            } header: {
                Text("Recent · \(articles.count) editorials")
                    .foregroundColor(.secondary)
            }
        }
        .listStyle(.plain)
    }

    private var headerCard: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 10)
                .fill(LinearGradient(colors: [.accentColor, .accentColor.opacity(0.5)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 84, height: 84)
                .overlay(Image(systemName: "newspaper.fill")
                    .font(.system(size: 32)).foregroundColor(.white))

            VStack(alignment: .leading, spacing: 4) {
                Text(playlistName).font(.title3).fontWeight(.bold)
                Text("\(articles.count) recent editorials · auto-narrated")
                    .font(.caption).foregroundColor(.secondary)

                Button {
                    if player.isActive && player.playlistName == playlistName {
                        player.togglePlayPause()
                    } else {
                        player.play(playlist: playlistName, articles: articles, startAt: 0)
                    }
                } label: {
                    Label(playAllLabel, systemImage: playAllIcon)
                        .font(.subheadline).fontWeight(.semibold)
                        .padding(.horizontal, 18).padding(.vertical, 8)
                        .background(Color.accentColor).foregroundColor(.white)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
                .disabled(articles.isEmpty)
            }
            Spacer(minLength: 0)
        }
    }

    private var playAllLabel: String {
        if player.playlistName == playlistName && player.state == .playing { return "Pause" }
        if player.playlistName == playlistName && player.state == .paused { return "Resume" }
        return "Play All"
    }
    private var playAllIcon: String {
        player.playlistName == playlistName && player.state == .playing ? "pause.fill" : "play.fill"
    }

    private func trackRow(index: Int, article: FeedArticle) -> some View {
        let isCurrent = player.playlistName == playlistName && player.isCurrent(article.id)
        return HStack(spacing: 12) {
            ZStack {
                if isCurrent {
                    Image(systemName: player.state == .loading ? "waveform"
                          : player.state == .playing ? "speaker.wave.2.fill" : "speaker.fill")
                        .foregroundColor(.accentColor)
                } else {
                    Text("\(index + 1)").foregroundColor(.secondary).font(.footnote.monospacedDigit())
                }
            }
            .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(article.title)
                    .font(.subheadline).lineLimit(2)
                    .foregroundColor(isCurrent ? .accentColor : .primary)
                Text(article.source)
                    .font(.caption2).foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    // MARK: Now-playing bar

    private var nowPlayingBar: some View {
        VStack(spacing: 12) {
            artwork
            VStack(spacing: 3) {
                Text(player.current?.title ?? "—")
                    .font(.subheadline).fontWeight(.semibold).lineLimit(2)
                    .multilineTextAlignment(.center)
                Text(player.state == .loading ? "Loading…" : (player.current?.source ?? player.playlistName))
                    .font(.caption2).foregroundColor(.secondary).lineLimit(1)
            }
            HStack(spacing: 36) {
                Button { player.previous() } label: { Image(systemName: "backward.fill").font(.title3) }
                Button { player.togglePlayPause() } label: {
                    if player.state == .loading {
                        ProgressView().scaleEffect(0.9).frame(width: 40, height: 40)
                    } else {
                        Image(systemName: player.state == .playing ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 40))
                    }
                }
                Button { player.next() } label: { Image(systemName: "forward.fill").font(.title3) }
            }
            .overlay(alignment: .trailing) {
                Button { player.stop() } label: { Image(systemName: "xmark") }
                    .foregroundColor(.secondary).padding(.trailing, 4)
            }
        }
        .foregroundColor(.primary)
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 10)
        .background(.ultraThinMaterial)
        .task(id: player.current?.id) { await loadArtwork() }
    }

    /// Scraped artwork for the now-playing track (falls back to a glyph).
    private var artwork: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemBackground))
            if let artworkURL {
                AsyncImage(url: artworkURL) { phase in
                    if case .success(let img) = phase {
                        img.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: "newspaper").font(.largeTitle).foregroundColor(.secondary)
                    }
                }
            } else {
                Image(systemName: "newspaper").font(.largeTitle).foregroundColor(.secondary)
            }
        }
        .frame(height: 160)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func loadArtwork() async {
        guard let article = player.current else { artworkURL = nil; return }
        artworkURL = await FeedManager.shared.fetchThumbnail(for: article)
    }

    private var emptyError: some View {
        VStack(spacing: 16) {
            Image(systemName: "wifi.slash").font(.system(size: 48)).foregroundColor(.secondary)
            Text("Could not load editorials").font(.headline)
            Text("Check your connection and pull to refresh.")
                .font(.subheadline).foregroundColor(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func load() async {
        isLoading = true; loadError = false
        let fetched = await FeedManager.shared.fetchAll()
        articles = fetched; loadError = fetched.isEmpty
        isLoading = false
    }
}
