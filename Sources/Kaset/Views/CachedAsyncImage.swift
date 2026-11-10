import SwiftUI

// MARK: - CachedAsyncImageRequest

private struct CachedAsyncImageRequest: Equatable {
    let url: URL?
    let targetSize: CGSize
}

// MARK: - CachedAsyncImageTaskID

/// Restarts the load task when a memory-cache hit stops being available (evicted),
/// so a view showing a cached image never needs to copy it into its own state.
private struct CachedAsyncImageTaskID: Equatable {
    let request: CachedAsyncImageRequest
    let isMemoryHit: Bool
}

// MARK: - CachedAsyncImageDisplayedImage

/// The memory-cache hit this view is currently showing. A plain reference (not
/// observed), so recording it from `body` costs no extra body pass. It lets a view
/// keep its on-screen bitmap after the shared cache trims or evicts the entry —
/// otherwise the next body pass would flash the placeholder and fade the image back
/// in from disk. Holds nothing a rendered `Image` wasn't already retaining.
private final class CachedAsyncImageDisplayedImage {
    var request: CachedAsyncImageRequest?
    var image: NSImage?
}

// MARK: - CachedAsyncImage

/// A cached version of AsyncImage that uses ImageCache.
/// Includes a smooth crossfade transition when the image loads.
struct CachedAsyncImage<Content: View, Placeholder: View>: View {
    let url: URL?
    /// Target size for image downsampling, in points. Pass the actual display size:
    /// `ImageCache` already decodes at 2× for Retina, so do not pre-multiply.
    var targetSize: CGSize = .init(width: 320, height: 320)
    /// Optional callback invoked when an image load fails.
    var onFailure: (@MainActor () -> Void)?
    @ViewBuilder let content: (Image) -> Content
    @ViewBuilder let placeholder: () -> Placeholder

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    @State private var image: NSImage?
    @State private var isLoaded = false
    @State private var displayed = CachedAsyncImageDisplayedImage()

    private var request: CachedAsyncImageRequest {
        CachedAsyncImageRequest(url: self.url, targetSize: self.targetSize)
    }

    /// Whether to animate the image appearance.
    private var shouldAnimate: Bool {
        !self.accessibilityReduceMotion
    }

    /// A synchronous memory-cache hit for the current request, if the async load hasn't landed yet.
    private var memoryCachedImage: NSImage? {
        guard self.image == nil, let url = self.url else { return nil }
        let request = self.request
        if let hit = ImageCache.shared.cachedImage(for: url, targetSize: self.targetSize) {
            self.displayed.request = request
            self.displayed.image = hit
            return hit
        }
        // Trimmed from the shared tier while still on screen: keep showing it.
        if self.displayed.request == request {
            return self.displayed.image
        }
        return nil
    }

    var body: some View {
        // A memory-cache hit renders on the first frame with no placeholder and no
        // fade, so views re-realized while scrolling (lazy stack rows) don't pay a
        // placeholder render + async hop + crossfade animation each time.
        let cached = self.memoryCachedImage
        let isMemoryHit = cached != nil
        ZStack {
            if let image = self.image ?? cached {
                self.content(Image(nsImage: image))
                    .opacity(self.isLoaded || isMemoryHit ? 1 : 0)
                    .animation(self.shouldAnimate ? .easeIn(duration: 0.25) : nil, value: self.isLoaded)
            } else {
                self.placeholder()
            }
        }
        .onChange(of: self.request) { _, newRequest in
            // Reset state when the underlying request changes for proper UX.
            // Include targetSize so a reused view does not keep a stale decode.
            self.image = nil
            self.isLoaded = false
            // Drop the previous request's bitmap unless this body pass already
            // recorded a hit for the new one (reused views, e.g. the Now Playing
            // artwork, would otherwise pin the old track's decode).
            if self.displayed.request != newRequest {
                self.displayed.request = nil
                self.displayed.image = nil
            }
        }
        // A memory hit needs no load and no state write (which would cost another body
        // pass per realized row). If it is evicted, the next body pass flips the ID and
        // the task loads it from disk.
        .task(id: CachedAsyncImageTaskID(request: self.request, isMemoryHit: isMemoryHit)) {
            let request = self.request
            guard !isMemoryHit, let url = request.url else { return }
            let loadedImage = await ImageCache.shared.image(for: url, targetSize: request.targetSize)
            guard !Task.isCancelled, self.request == request else { return }

            guard let loadedImage else {
                self.image = nil
                self.isLoaded = false
                self.onFailure?()
                return
            }

            self.image = loadedImage
            self.isLoaded = true
        }
    }
}

// MARK: - SizedProgressView

/// A simple ProgressView wrapper with proper sizing to avoid AppKit constraint warnings.
struct SizedProgressView: View {
    var body: some View {
        ProgressView()
            .controlSize(.regular)
            .frame(width: 20, height: 20)
    }
}

extension CachedAsyncImage where Placeholder == SizedProgressView {
    /// Convenience initializer with default ProgressView placeholder.
    init(
        url: URL?,
        targetSize: CGSize = .init(width: 320, height: 320),
        onFailure: (@MainActor () -> Void)? = nil,
        @ViewBuilder content: @escaping (Image) -> Content
    ) {
        self.url = url
        self.targetSize = targetSize
        self.onFailure = onFailure
        self.content = content
        self.placeholder = { SizedProgressView() }
    }
}
