import SwiftUI
import WebKit

// MARK: - VideoPlayerWindow

/// Floating window for video playback.
struct VideoPlayerWindow: View {
    @Environment(PlayerService.self) private var playerService

    var body: some View {
        // The Window controls the aspect ratio and min size;
        // using .fit here can cause the webview to shrink/be letterboxed incorrectly during fast resize.
        Group {
            if self.playerService.isNowPlayingVideoVisible {
                // Fullscreen Now Playing has the WebView; the window is ordered out meanwhile.
                // Remounting the container when it hands the WebView back reattaches it here.
                Color.black
            } else {
                VideoWebViewContainer(videoId: self.playerService.pendingPlayVideoId)
                    .overlay {
                        // A song without a music video streams audio only: show its artwork
                        // instead of a black frame (the WebView stays mounted underneath).
                        if !self.playerService.canShowCurrentTrackVideo {
                            VideoPlayerWindowArtwork(url: self.playerService.currentTrack?.thumbnailURL)
                        }
                    }
            }
        }
        .background(.black)
        .accessibilityIdentifier(AccessibilityID.VideoWindow.container)
    }
}

// MARK: - VideoPlayerWindowArtwork

/// The track's artwork, fitted on black, for a track with no video to show.
private struct VideoPlayerWindowArtwork: View {
    let url: URL?

    var body: some View {
        Color.black
            .overlay {
                CachedAsyncImage(url: self.url, targetSize: CGSize(width: 640, height: 640)) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(.rect(cornerRadius: TuneTheme.Radius.artwork, style: .continuous))
                        .padding(TuneTheme.Spacing.itemGap)
                } placeholder: {
                    Color.black
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

// MARK: - VideoWebViewContainer

/// NSViewRepresentable container for the video WebView.
struct VideoWebViewContainer: NSViewRepresentable {
    @Environment(WebKitManager.self) private var webKitManager
    @Environment(PlayerService.self) private var playerService
    @Environment(AuthService.self) private var authService

    let videoId: String?

    func makeNSView(context _: Context) -> VideoContainerView {
        DiagnosticsLogger.player.info("VideoWebViewContainer.makeNSView called")
        let container = VideoContainerView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        self.attachPlayerWebView(to: container)
        return container
    }

    func updateNSView(_ nsView: VideoContainerView, context _: Context) {
        DiagnosticsLogger.player.debug("VideoWebViewContainer.updateNSView called")
        self.attachPlayerWebView(to: nsView)
    }

    private func attachPlayerWebView(to container: VideoContainerView) {
        _ = SingletonPlayerWebView.shared.getWebView(
            webKitManager: self.webKitManager,
            playerService: self.playerService,
            usesCookieFreeDataStore: self.authService.shouldUseCookieFreePlaybackDataStore
        )
        SingletonPlayerWebView.shared.ensureInHierarchy(container: container)
        SingletonPlayerWebView.shared.updateDisplayMode(.video)

        if let videoId = self.videoId,
           self.playerService.shouldAutoloadPendingVideo,
           SingletonPlayerWebView.shared.currentVideoId != videoId
        {
            SingletonPlayerWebView.shared.loadVideo(videoId: videoId)
        }
    }
}

// MARK: - VideoContainerView

/// Custom NSView that observes frame changes and re-injects CSS.
final class VideoContainerView: NSView {
    /// When true the container and the WebView inside it never take the pointer: clicks and
    /// hovers fall through to the SwiftUI view underneath (fullscreen Now Playing's slot,
    /// where the page's own controls must stay out of reach).
    var passesPointerEventsThrough = false

    override func hitTest(_ point: NSPoint) -> NSView? {
        self.passesPointerEventsThrough ? nil : super.hitTest(point)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(self.frameDidChange),
            name: NSView.frameDidChangeNotification,
            object: self
        )
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private var refreshTask: Task<Void, Never>?

    @objc private func frameDidChange(_: Notification) {
        // Debounce slightly to prevent JS overload during continuous resize
        self.refreshTask?.cancel()
        self.refreshTask = Task { @MainActor in
            try? await Task.sleep(for: .nanoseconds(16_666_666)) // ~60fps
            if !Task.isCancelled, SingletonPlayerWebView.shared.displayMode == .video {
                SingletonPlayerWebView.shared.refreshVideoModeCSS()
            }
        }
    }

    deinit {
        self.refreshTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }
}

// MARK: - Preview

#Preview {
    VideoPlayerWindow()
        .environment(PlayerService())
        .environment(WebKitManager.shared)
        .environment(AuthService())
        .frame(width: 480, height: 270)
}
