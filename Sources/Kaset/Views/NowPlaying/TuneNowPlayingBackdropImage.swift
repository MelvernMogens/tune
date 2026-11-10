import AppKit
import CoreImage
import SwiftUI

// MARK: - TuneNowPlayingBackdropRenderer

/// Bakes the Now Playing backdrop (artwork saturated, darkened and blurred far past
/// recognition) into one small bitmap that the view simply stretches over the window.
///
/// The view used to apply `.saturation`, `.colorMultiply` and a 90-point `.blur` live to a
/// window-sized layer inside a `.drawingGroup()`. That keeps a full-window offscreen
/// bitmap (≈24 MB on a 1512×982 pt Retina window, twice that during a track crossfade)
/// plus the blur's intermediates for as long as Now Playing is open. The blurred result
/// has no detail finer than the blur, so a 256 px bitmap scaled up is visually the same
/// and costs 256 KB.
enum TuneNowPlayingBackdropRenderer {
    /// Edge of the baked bitmap in pixels.
    static let outputEdge = 256

    struct Look: Equatable {
        var saturation: Double = 1.9
        var brightness: Double = TuneTheme.NowPlaying.backdropBrightness
        /// Blur radius in points of the displayed (aspect-filled) artwork.
        var blurRadius: CGFloat = TuneTheme.NowPlaying.backdropBlur
    }

    /// Software context: the bitmap is tiny, so no Metal resources are worth holding.
    private static let context = CIContext(options: [
        .useSoftwareRenderer: true,
        .cacheIntermediates: false,
        .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any,
    ])

    /// Blur radius in bitmap pixels for artwork aspect-filled over `viewSize` points.
    /// The bitmap's long edge spans the filled artwork's long edge.
    static func pixelBlurRadius(look: Look, sourceAspect: CGFloat, viewSize: CGSize) -> CGFloat {
        guard viewSize.width > 0, viewSize.height > 0, sourceAspect > 0, sourceAspect.isFinite else {
            return 0
        }
        let viewAspect = viewSize.width / viewSize.height
        // Aspect fill: the filled artwork's size in points.
        let filled = sourceAspect > viewAspect
            ? CGSize(width: viewSize.height * sourceAspect, height: viewSize.height)
            : CGSize(width: viewSize.width, height: viewSize.width / sourceAspect)
        let filledLongEdge = max(filled.width, filled.height)
        return look.blurRadius * CGFloat(Self.outputEdge) / filledLongEdge
    }

    /// Renders the backdrop for artwork shown aspect-filled over `viewSize` points.
    /// Pure and thread-safe; returns nil for an undecodable image or empty view.
    static func render(_ image: NSImage, viewSize: CGSize, look: Look = Look()) -> NSImage? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              cgImage.width > 0, cgImage.height > 0
        else { return nil }
        let sourceAspect = CGFloat(cgImage.width) / CGFloat(cgImage.height)
        let radius = Self.pixelBlurRadius(look: look, sourceAspect: sourceAspect, viewSize: viewSize)
        guard radius > 0 else { return nil }

        // Long edge → outputEdge, preserving the artwork's aspect.
        let scale = CGFloat(Self.outputEdge) / CGFloat(max(cgImage.width, cgImage.height))
        let outputSize = CGSize(
            width: max(1, (CGFloat(cgImage.width) * scale).rounded()),
            height: max(1, (CGFloat(cgImage.height) * scale).rounded())
        )
        var working = CIImage(cgImage: cgImage)
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let extent = CGRect(origin: .zero, size: outputSize)

        // Same order and values as the old live filters: saturate, darken, then an
        // edge-clamped ("opaque") blur.
        working = working.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: look.saturation,
        ])
        let gain = CIVector(x: look.brightness, y: 0, z: 0, w: 0)
        working = working.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": gain,
            "inputGVector": CIVector(x: 0, y: look.brightness, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: look.brightness, w: 0),
        ])
        working = working
            .clampedToExtent()
            .applyingGaussianBlur(sigma: Double(radius))
            .cropped(to: extent)

        guard let output = Self.context.createCGImage(
            working,
            from: extent,
            format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
        )
        else { return nil }
        return NSImage(cgImage: output, size: outputSize)
    }

    // MARK: Cache

    /// A few recent backdrops so reopening Now Playing or a resize back is instant.
    /// 256 KB each.
    nonisolated(unsafe) private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 6
        return cache
    }()

    static func cacheKey(url: URL, sizeBucket: CGSize) -> NSString {
        "\(url.absoluteString)|\(Int(sizeBucket.width))x\(Int(sizeBucket.height))" as NSString
    }

    static func cached(url: URL, sizeBucket: CGSize) -> NSImage? {
        Self.cache.object(forKey: Self.cacheKey(url: url, sizeBucket: sizeBucket))
    }

    static func store(_ image: NSImage, url: URL, sizeBucket: CGSize) {
        Self.cache.setObject(image, forKey: Self.cacheKey(url: url, sizeBucket: sizeBucket))
    }

    /// View sizes snap to 128 pt steps so a live window resize re-renders a handful of
    /// times, not every frame. The blur radius changes by at most a few percent per step.
    static func sizeBucket(for size: CGSize) -> CGSize {
        let step: CGFloat = 128
        return CGSize(
            width: max(step, (size.width / step).rounded() * step),
            height: max(step, (size.height / step).rounded() * step)
        )
    }
}

// MARK: - TuneNowPlayingBackdropArtwork

/// The baked backdrop, aspect-filled. Shows nothing until the first render lands (the
/// artwork-tinted field behind it is the placeholder, as before) and keeps the previous
/// render of the same artwork through resizes so it never blinks.
struct TuneNowPlayingBackdropArtwork: View {
    let url: URL?
    /// Synchronous source for snapshot renders, which never run `.task`.
    let artworkOverride: NSImage?

    /// The latest bake and the URL it came from; only shown for that URL.
    @State private var rendered: (url: URL, image: NSImage)?

    var body: some View {
        GeometryReader { proxy in
            let bucket = TuneNowPlayingBackdropRenderer.sizeBucket(for: proxy.size)
            ZStack {
                if let image = self.displayedImage(bucket: bucket) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fill)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .transition(.opacity)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .task(id: RenderKey(url: self.url, bucket: bucket)) {
                await self.render(bucket: bucket)
            }
        }
    }

    private struct RenderKey: Equatable {
        let url: URL?
        let bucket: CGSize
    }

    private func displayedImage(bucket: CGSize) -> NSImage? {
        if let artworkOverride {
            return TuneNowPlayingBackdropRenderer.render(artworkOverride, viewSize: bucket)
        }
        guard let url else { return nil }
        if let cached = TuneNowPlayingBackdropRenderer.cached(url: url, sizeBucket: bucket) {
            return cached
        }
        // Another size bucket of the same artwork, kept through a resize; never another track's.
        guard let rendered, rendered.url == url else { return nil }
        return rendered.image
    }

    private func render(bucket: CGSize) async {
        guard self.artworkOverride == nil, let url = self.url else { return }
        if TuneNowPlayingBackdropRenderer.cached(url: url, sizeBucket: bucket) != nil { return }
        guard let source = await ImageCache.shared.image(
            for: url,
            targetSize: TuneTheme.NowPlaying.backdropDecodeSize
        ) else { return }
        guard !Task.isCancelled else { return }
        let output = await Task.detached(priority: .userInitiated) {
            TuneNowPlayingBackdropRenderer.render(source, viewSize: bucket)
        }.value
        guard let output, !Task.isCancelled else { return }
        TuneNowPlayingBackdropRenderer.store(output, url: url, sizeBucket: bucket)
        withAnimation(.easeOut(duration: 0.3)) {
            self.rendered = (url, output)
        }
    }
}
