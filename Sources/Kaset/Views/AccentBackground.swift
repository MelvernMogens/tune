import SwiftUI

// MARK: - AccentBackground

/// A page background tinted by colors extracted from an image (artist, podcast pages).
///
/// Tune (C2) is dark and crisp, not muddy: the page sits on the near-black window surface and
/// the artwork only washes the top third with a faint tint that fades out cleanly.
struct AccentBackground: View {
    let imageURL: URL?
    @State private var palette: ColorExtractor.ColorPalette = .default
    @State private var isLoaded = false

    /// Strength of the artwork tint at the very top of the page.
    static let tintOpacity = 0.22

    var body: some View {
        ZStack {
            TuneTheme.Palette.background

            LinearGradient(
                colors: [
                    self.palette.primary.opacity(Self.tintOpacity),
                    self.palette.primary.opacity(Self.tintOpacity / 3),
                    Color.clear,
                ],
                startPoint: .top,
                endPoint: UnitPoint(x: 0.5, y: 0.4)
            )
        }
        .animation(.easeInOut(duration: 0.5), value: self.isLoaded)
        .task(id: self.imageURL) {
            await self.loadPalette()
        }
    }

    private func loadPalette() async {
        guard let url = imageURL else {
            self.palette = .default
            self.isLoaded = true
            return
        }

        let extracted = await ColorExtractor.cachedPalette(for: url)
        guard !Task.isCancelled else { return }
        self.palette = extracted
        self.isLoaded = true
    }
}

// MARK: - AccentBackgroundModifier

/// View modifier to apply accent background based on album art.
struct AccentBackgroundModifier: ViewModifier {
    let imageURL: URL?

    func body(content: Content) -> some View {
        content
            .background {
                AccentBackground(imageURL: self.imageURL)
                    .ignoresSafeArea()
            }
    }
}

extension View {
    /// Applies an accent color background gradient extracted from the given image URL.
    /// - Parameter imageURL: The URL of the image to extract colors from.
    /// - Returns: A view with the accent background applied.
    func accentBackground(from imageURL: URL?) -> some View {
        modifier(AccentBackgroundModifier(imageURL: imageURL))
    }
}

#Preview {
    VStack {
        Text("Accent Background Preview")
            .font(.largeTitle)
            .foregroundStyle(.primary)
    }
    .frame(width: 400, height: 600)
    .accentBackground(from: nil)
}
