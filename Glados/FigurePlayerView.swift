import SwiftUI

struct FigurePlayerView: View {
    @EnvironmentObject var viewModel: PlayerViewModel
    @State private var sliderValue: Double = 0
    @State private var isDragging = false

    private var currentPanel: FigurePanel? {
        guard viewModel.currentPanelIndex < viewModel.panels.count else { return nil }
        return viewModel.panels[viewModel.currentPanelIndex]
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            figureArea
            Divider()
            controls
        }
        .onReceive(viewModel.player.$currentTime) { time in
            if !isDragging { sliderValue = viewModel.progress }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(viewModel.articleTitle)
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button { viewModel.showAPIKeySetup = true } label: {
                Image(systemName: "key").font(.caption).foregroundColor(.secondary)
            }
            Button { viewModel.stop() } label: {
                Image(systemName: "xmark").font(.caption).foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    // MARK: - Figure area

    @ViewBuilder
    private var figureArea: some View {
        if let panel = currentPanel {
            VStack(spacing: 0) {
                ZStack(alignment: .bottomLeading) {
                    AsyncImage(url: panel.imageURL) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFit()
                        case .failure, .empty:
                            Color(.secondarySystemBackground)
                                .overlay(
                                    Image(systemName: "photo")
                                        .font(.system(size: 40))
                                        .foregroundColor(.secondary)
                                )
                        @unknown default:
                            ProgressView()
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 240)
                    .clipped()

                    panelBadge(panel: panel)
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        if !panel.figureTitle.isEmpty {
                            Text(panel.figureTitle)
                                .font(.footnote.bold())
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if !panel.legendText.isEmpty {
                            Text(panel.legendText)
                                .font(.footnote)
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
            }
        } else {
            Spacer()
            Text("No figure data available.")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Spacer()
        }
    }

    private func panelBadge(panel: FigurePanel) -> some View {
        let label = panel.label.isEmpty
            ? "Fig. \(panel.figureNumber)"
            : "Fig. \(panel.figureNumber)\(panel.label)"
        return Text(label)
            .font(.caption2.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
            .padding(8)
    }

    // MARK: - Playback controls

    private var controls: some View {
        HStack(spacing: 10) {
            Button { viewModel.player.togglePlayPause() } label: {
                Image(systemName: viewModel.player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 18))
                    .frame(width: 36, height: 36)
                    .background(Color.accentColor.opacity(0.12))
                    .clipShape(Circle())
            }
            VStack(spacing: 2) {
                Slider(value: $sliderValue, in: 0...1) { editing in
                    isDragging = editing
                    if !editing { viewModel.player.seek(to: sliderValue) }
                }
                HStack {
                    Text(viewModel.currentTimeFormatted)
                    Spacer()
                    Text(viewModel.durationFormatted)
                }
                .font(.system(size: 10).monospacedDigit())
                .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}
