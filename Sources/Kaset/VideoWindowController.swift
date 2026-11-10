import AppKit
import SwiftUI

// MARK: - VideoWindowController

/// Manages the floating video window.
@MainActor
final class VideoWindowController {
    static let shared = VideoWindowController()

    private var window: NSWindow?
    private var hostingView: NSHostingView<AnyView>?

    /// Reference to PlayerService to sync showVideo state
    private weak var playerService: PlayerService?

    /// Flag to prevent re-entrant close handling
    private var isClosing = false

    /// Frame persistence key
    private let frameAutosaveKey = "KasetVideoWindow"

    /// Whether fullscreen Now Playing has borrowed the WebView for its video slot. The
    /// window stays open (and `showVideo` stays true) but is ordered out until it's back.
    private var isYieldingToNowPlaying = false

    private init() {}

    /// Shows the video window.
    func show(
        playerService: PlayerService,
        webKitManager: WebKitManager,
        authService: AuthService
    ) {
        // Store reference to sync state on close
        self.playerService = playerService
        // Trust the live state over a flag left from an earlier window.
        self.isYieldingToNowPlaying = playerService.isNowPlayingVideoVisible

        // Start grace period to prevent race condition when video element is moved
        playerService.videoWindowDidOpen()

        if let existingWindow = self.window {
            // Window exists - just bring it to front without stealing focus
            self.isClosing = false // Reset in case of interrupted close
            if !self.isYieldingToNowPlaying {
                existingWindow.orderFront(nil)
            }
            // Ensure video mode is active
            SingletonPlayerWebView.shared.updateDisplayMode(.video)
            return
        }

        let contentView = VideoPlayerWindow()
            .environment(playerService)
            .environment(webKitManager)
            .environment(authService)

        let hostingView = NSHostingView(rootView: AnyView(contentView))
        self.hostingView = hostingView

        // Load saved frame or use default
        let defaultRect = NSRect(x: 0, y: 0, width: 480, height: 270)
        let window = NSWindow(
            contentRect: defaultRect,
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        window.contentView = hostingView
        window.isReleasedWhenClosed = false
        window.title = "Video"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        // Normal window level (not always-on-top) for better UX
        window.level = .normal
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.aspectRatio = NSSize(width: 16, height: 9)
        window.minSize = NSSize(width: 160, height: 90)
        window.backgroundColor = .black

        // Use Sparkle/macOS style frame persistence
        window.setFrameAutosaveName(self.frameAutosaveKey)

        // Set accessibility identifier for UI testing
        window.identifier = NSUserInterfaceItemIdentifier(AccessibilityID.VideoWindow.container)

        // If no autosaved frame exists yet, position it in a sane default location (bottom right)
        if !window.setFrameUsingName(self.frameAutosaveKey) {
            self.positionAtDefaultLocation(window: window)
        }

        // Show the floating video window without taking key focus away from the main window,
        // so the player bar toggle remains a true one-click toggle while video is open.
        // While fullscreen Now Playing shows the video it stays out until that hands it back.
        if !self.isYieldingToNowPlaying {
            window.orderFront(nil)
        }
        self.window = window
        self.isClosing = false

        // Observe window close (for red X button)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(self.windowWillClose),
            name: NSWindow.willCloseNotification,
            object: window
        )

        // Update WebView display mode for video
        SingletonPlayerWebView.shared.updateDisplayMode(.video)
    }

    /// Fullscreen Now Playing took (`true`) or returned (`false`) the playback WebView. The
    /// window steps out of sight meanwhile; on return `VideoPlayerWindow` remounts its
    /// container, which reattaches the WebView, and the window comes back to the front.
    func setYieldsToNowPlaying(_ yields: Bool) {
        guard self.isYieldingToNowPlaying != yields else { return }
        self.isYieldingToNowPlaying = yields
        guard let window = self.window, !self.isClosing else { return }
        if yields {
            window.orderOut(nil)
        } else {
            window.orderFront(nil)
        }
    }

    /// Closes the video window programmatically (called when showVideo becomes false).
    func close() {
        // Prevent re-entrant calls
        guard !self.isClosing else { return }
        guard let window = self.window else { return }

        self.isClosing = true

        // Remove observer before closing to prevent windowWillClose from firing
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: window)

        // Ensure frame is saved
        window.saveFrame(usingName: self.frameAutosaveKey)

        // Clean up
        self.performCleanup()

        // Actually close the window
        window.close()
    }

    /// Called when window is closed via the red X button.
    @objc private func windowWillClose(_ notification: Notification) {
        // Prevent re-entrant calls
        guard !self.isClosing else { return }
        self.isClosing = true

        // Save final position
        if let window = notification.object as? NSWindow {
            window.saveFrame(usingName: self.frameAutosaveKey)
        }

        // Clean up
        self.performCleanup()

        // Sync PlayerService state - this handles close via red button
        // This will trigger MainWindow.onChange which calls close(), but isClosing prevents re-entry
        if self.playerService?.showVideo == true {
            self.playerService?.showVideo = false
        }
    }

    /// Shared cleanup logic for both close paths.
    private func performCleanup() {
        // Clear grace period
        self.playerService?.videoWindowDidClose()

        // Return WebView to hidden mode (removes video container CSS) — unless fullscreen
        // Now Playing is showing the video right now; it hides the WebView when it's done.
        if self.playerService?.isNowPlayingVideoVisible != true {
            SingletonPlayerWebView.shared.updateDisplayMode(.hidden)
        }

        // Clear references
        self.window = nil
        self.hostingView = nil

        // Reset close guard so future close operations can proceed
        self.isClosing = false
    }

    private func positionAtDefaultLocation(window: NSWindow) {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let windowSize = window.frame.size
        let padding: CGFloat = 40

        // Default to top right so the floating window does not cover player-bar controls
        // on first launch, keeping the video toggle reachable for a true second-click close.
        let origin = NSPoint(
            x: screenFrame.maxX - windowSize.width - padding,
            y: screenFrame.maxY - windowSize.height - padding
        )

        window.setFrameOrigin(origin)
    }
}
