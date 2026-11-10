import SwiftUI

// MARK: - TuneArtworkView

/// Artwork for the C2 pages: soft continuous corners (radius picked from the
/// Tune scale by size unless given), aspect-fill crop, a raised placeholder, and
/// a 1 px inset edge on the same rounded shape so dark covers don't vanish into
/// the background. Tries each candidate URL in order when one fails.
struct TuneArtworkView: View {
    let urls: [URL]
    let size: CGSize
    var placeholderSymbol: String = "music.note"
    /// The 1 px inset edge; off only when an enclosing block draws the edge instead.
    var showsEdge = true
    /// Corner radius; nil picks the scale step for `size`.
    var cornerRadius: CGFloat?

    @State private var failedURLs: Set<URL> = []

    private var radius: CGFloat {
        self.cornerRadius ?? TuneTheme.Radius.artwork(for: self.size)
    }

    var body: some View {
        let url = self.urls.first { !self.failedURLs.contains($0) }
        let shape = RoundedRectangle.tuneRounded(self.radius)
        ZStack {
            Rectangle()
                .fill(TuneTheme.Palette.raised)
            if let url {
                CachedAsyncImage(url: url, targetSize: self.size, onFailure: self.failureHandler(for: url)) { image in
                    image
                        .resizable()
                        .scaledToFill()
                } placeholder: {
                    self.placeholder
                }
            } else {
                self.placeholder
            }
        }
        .frame(width: self.size.width, height: self.size.height)
        .clipShape(shape)
        .overlay {
            if self.showsEdge {
                shape
                    .strokeBorder(TuneTheme.Palette.artworkEdge, lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityHidden(true)
    }

    private var placeholder: some View {
        Image(systemName: self.placeholderSymbol)
            .font(TuneTheme.Typeface.section)
            .foregroundStyle(TuneTheme.Palette.inkDim)
    }

    private func failureHandler(for url: URL) -> (@MainActor () -> Void)? {
        guard let index = self.urls.firstIndex(of: url), index < self.urls.count - 1 else { return nil }
        return {
            self.failedURLs.insert(url)
        }
    }
}

// MARK: - Artwork URLs

extension URL {
    /// Re-requests Google-hosted artwork at `side` points (2× for Retina), so big
    /// hero tiles don't upscale a 226 px thumbnail. Other hosts are returned as is.
    func tuneArtworkURL(side: CGFloat) -> URL {
        guard let host, host.contains("googleusercontent.com") || host.contains("ggpht.com") else {
            return self
        }
        let pixels = Int(min(max(side * 2, 120), 1200).rounded())
        var string = self.absoluteString
        if let range = string.range(of: #"=w\d+-h\d+"#, options: .regularExpression) {
            string.replaceSubrange(range, with: "=w\(pixels)-h\(pixels)")
        } else if let range = string.range(of: #"=s\d+"#, options: .regularExpression) {
            string.replaceSubrange(range, with: "=s\(pixels)")
        }
        return URL(string: string) ?? self
    }
}

extension HomeSectionItem {
    /// Artwork candidates for a C2 tile. Video songs prefer the wide `hq720`
    /// frame (no letterbox bars), which crops cleanly to 16:9 or to a square.
    func tuneArtworkURLs(side: CGFloat) -> [URL] {
        var candidates: [URL?] = []
        if case let .song(song) = self, self.isVideoSong {
            candidates = [
                song.wideHighQualityThumbnailURL,
                self.thumbnailURL?.highQualityThumbnailURL,
                song.fallbackThumbnailURL,
            ]
        } else {
            candidates = [
                self.thumbnailURL?.highQualityThumbnailURL?.tuneArtworkURL(side: side),
                self.thumbnailURL?.highQualityThumbnailURL,
            ]
            if case let .song(song) = self {
                candidates.append(song.fallbackThumbnailURL)
            }
        }
        var seen = Set<URL>()
        return candidates.compactMap(\.self).filter { seen.insert($0).inserted }
    }

    var tunePlaceholderSymbol: String {
        switch self {
        case .song: self.isVideoSong ? "play.rectangle" : "music.note"
        case .album: "square.stack"
        case .playlist: "music.note.list"
        case .artist: "person"
        }
    }
}
