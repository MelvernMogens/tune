import AppKit
import SwiftUI

// MARK: - TuneNowPlayingVideoToggle

/// The transport's SONG · VIDEO switch. Like YouTube Music's own Song/Video toggle: the
/// preference sticks across tracks, and a track without a video falls back to the artwork
/// with the switch dimmed (the preference is kept for the next video).
struct TuneNowPlayingVideoToggle: Equatable {
    enum Mode: Equatable {
        case song
        case video
    }

    /// Persisted `tune.nowPlaying.prefersVideo`.
    var prefersVideo: Bool
    /// `PlayerService.canShowCurrentTrackVideo` — the status line's VIDEO availability.
    var isAvailable: Bool

    static let unavailable = TuneNowPlayingVideoToggle(prefersVideo: false, isAvailable: false)

    /// The underlined side; nil while the track has no video (both sides dim).
    var activeMode: Mode? {
        guard self.isAvailable else { return nil }
        return self.prefersVideo ? .video : .song
    }

    /// Whether the overlay should host the playing video in its artwork slot.
    static func wantsVideoSlot(
        toggle: Self,
        isPresented: Bool,
        isMiniPlayerOnScreen: Bool
    ) -> Bool {
        isPresented && toggle.activeMode == .video && !isMiniPlayerOnScreen
    }

    /// Whether giving the slot up should happen at once. Only a lost video (track change,
    /// a flickering availability report) waits a beat, so a brief gap doesn't bounce the
    /// WebView out and back in.
    static func hidesVideoImmediately(
        toggle: Self,
        isPresented: Bool,
        isMiniPlayerOnScreen: Bool
    ) -> Bool {
        !isPresented || !toggle.prefersVideo || isMiniPlayerOnScreen
    }
}

// MARK: - TuneNowPlayingVideo

/// What the fullscreen view needs to know about the video: the switch's state and whether
/// the slot currently hosts the playback WebView.
struct TuneNowPlayingVideo: Equatable {
    var toggle: TuneNowPlayingVideoToggle
    /// `PlayerService.isNowPlayingVideoVisible`: the slot owns the WebView right now.
    var showsVideo: Bool

    static let unavailable = TuneNowPlayingVideo(toggle: .unavailable, showsVideo: false)
}

// MARK: - TuneNowPlayingVideoHosting

/// Hands the singleton playback WebView to fullscreen Now Playing's video slot and back.
///
/// Same audio stream throughout: the one WebView is reparented, never reloaded. While the
/// slot has it, the hidden 1×1 anchor is unmounted (`MainWindow.shouldMountPersistentPlayer`)
/// and an open video window is ordered out with its container unmounted. Giving it back
/// returns it to the video window if that's still open (video mode stays on), otherwise to
/// hidden mode, exactly as closing the video window does.
@MainActor
enum TuneNowPlayingVideoHosting {
    static func setVisible(_ visible: Bool, playerService: PlayerService) {
        guard playerService.isNowPlayingVideoVisible != visible else { return }
        DiagnosticsLogger.player.info("Now Playing video slot: \(visible ? "showing" : "hiding", privacy: .public)")
        playerService.isNowPlayingVideoVisible = visible
        if visible {
            // The slot attaches the WebView and enters video mode once it's mounted.
            VideoWindowController.shared.setYieldsToNowPlaying(true)
        } else {
            if !playerService.showVideo {
                SingletonPlayerWebView.shared.updateDisplayMode(.hidden)
            }
            // Remounts the video window's container (it reattaches the WebView) and fronts it.
            VideoWindowController.shared.setYieldsToNowPlaying(false)
        }
    }
}

// MARK: - TuneNowPlayingVideoSlot

/// Hosts the singleton playback WebView, in video mode, inside the artwork slot. Pointer
/// events pass through to the overlay: the page's own controls stay out of reach, just as
/// the transport stays the only control surface.
struct TuneNowPlayingVideoSlot: NSViewRepresentable {
    /// Continuous corners matching the artwork it replaces (the layer clips the WebView).
    var cornerRadius: CGFloat = TuneTheme.Radius.hero

    @Environment(WebKitManager.self) private var webKitManager
    @Environment(PlayerService.self) private var playerService
    @Environment(AuthService.self) private var authService

    func makeNSView(context _: Context) -> VideoContainerView {
        let container = VideoContainerView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        container.layer?.cornerCurve = .continuous
        container.layer?.masksToBounds = true
        container.layer?.cornerRadius = self.cornerRadius
        container.passesPointerEventsThrough = true
        self.attachPlayerWebView(to: container, takesOwnership: true)
        return container
    }

    func updateNSView(_ container: VideoContainerView, context _: Context) {
        if container.layer?.cornerRadius != self.cornerRadius {
            container.layer?.cornerRadius = self.cornerRadius
        }
        // Never pull the WebView back from another host here (that would fight it); only
        // re-adopt it if it was left detached, e.g. by a rebuild across an auth boundary.
        self.attachPlayerWebView(to: container, takesOwnership: false)
    }

    private func attachPlayerWebView(to container: VideoContainerView, takesOwnership: Bool) {
        let player = SingletonPlayerWebView.shared
        let webView = player.getWebView(
            webKitManager: self.webKitManager,
            playerService: self.playerService,
            usesCookieFreeDataStore: self.authService.shouldUseCookieFreePlaybackDataStore
        )
        guard self.playerService.isNowPlayingVideoVisible else { return }
        if takesOwnership || webView.superview == nil {
            player.ensureInHierarchy(container: container)
        }
        guard webView.superview === container else { return }
        player.updateDisplayMode(.video)

        // The hidden anchor this replaces also autoloads a pending track; keep doing that.
        if let videoId = self.playerService.pendingPlayVideoId,
           self.playerService.shouldAutoloadPendingVideo,
           player.currentVideoId != videoId
        {
            player.loadVideo(videoId: videoId)
        }
    }
}

// MARK: - TuneNowPlayingVideoSwitch

/// `SONG · VIDEO` in the transport: C2 caps, the active side ink and underlined, the other
/// muted. Without a video both sides dim to inkDim and the switch is inert.
struct TuneNowPlayingVideoSwitch: View {
    let toggle: TuneNowPlayingVideoToggle
    let setPrefersVideo: (Bool) -> Void

    var body: some View {
        HStack(spacing: TuneTheme.Spacing.unit * 1.5) {
            TuneNowPlayingTextToggle(
                title: Text("Song"),
                isOn: self.toggle.activeMode == .song,
                isEnabled: self.toggle.isAvailable,
                action: { self.setPrefersVideo(false) }
            )
            Text(verbatim: "·")
                .font(TuneTheme.Typeface.label)
                .foregroundStyle(TuneTheme.Palette.inkDim)
                .accessibilityHidden(true)
            TuneNowPlayingTextToggle(
                title: Text("Video"),
                isOn: self.toggle.activeMode == .video,
                isEnabled: self.toggle.isAvailable,
                action: { self.setPrefersVideo(true) }
            )
        }
        .help(self.toggle.isAvailable ? Text("Song or video (⇧⌘V)") : Text("No video for this track"))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Song or video"))
        .accessibilityIdentifier(TuneNowPlayingAccessibilityID.videoToggle)
    }
}
