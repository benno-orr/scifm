import SwiftUI

/// Figure-by-figure "seminar" mode: paste or pick a paper and sciFM walks each
/// figure panel — showing the subpanel image and speaking a synthesis of the
/// main-text and legend claims, auto-advancing panel to panel. Requires a paper
/// with extractable figures.
struct SeminarizeView: View {
    @EnvironmentObject var viewModel: PlayerViewModel
    @Binding var selectedTab: Int
    @State private var pastedURL = ""

    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                Spacer()
                Image(systemName: "rectangle.3.group")
                    .font(.system(size: 56)).foregroundColor(.accentColor)
                Text("Seminarize a paper")
                    .font(.headline)
                Text("Walk a paper figure by figure — each panel shown and explained from the main text and legend, auto-advancing as it plays. Needs a paper with extractable figures.")
                    .font(.subheadline).foregroundColor(.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal, 32)

                HStack {
                    TextField("Paste a paper URL…", text: $pastedURL)
                        .font(.caption).keyboardType(.URL).autocorrectionDisabled()
                        .padding(8).background(Color(.secondarySystemBackground)).cornerRadius(8)
                    Button("Go") { start() }
                        .disabled(pastedURL.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.horizontal)

                Text("Tip: tap the ⧉ icon on any paper in Commentaries, Reviews, or Primary to seminarize it.")
                    .font(.caption2).foregroundColor(.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal, 32)
                Spacer()
                Spacer()
            }
            .charcoalBackdrop()
            .navigationTitle("Seminarize")
        }
    }

    private func start() {
        guard let url = URL(string: pastedURL.trimmingCharacters(in: .whitespaces)) else { return }
        viewModel.load(url: url, kind: .seminar)
        pastedURL = ""
        selectedTab = 0
    }
}
