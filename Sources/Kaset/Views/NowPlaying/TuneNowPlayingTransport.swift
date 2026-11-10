import SwiftUI

// MARK: - TuneNowPlayingPlayback

/// Playback state the fullscreen transport renders.
struct TuneNowPlayingPlayback: Equatable {
    var isPlaying: Bool
    /// Seconds.
    var progress: TimeInterval
    /// Seconds; 0 when unknown.
    var duration: TimeInterval
    var isLiked: Bool
    var canLike: Bool
    var canSeek: Bool
    var repeatMode: PlayerService.RepeatMode = .off

    /// Progress clamped into `0...duration`, finite.
    var clampedProgress: TimeInterval {
        guard self.progress.isFinite, self.duration.isFinite, self.duration > 0 else { return 0 }
        return min(max(self.progress, 0), self.duration)
    }
}

// MARK: - TuneNowPlayingActions

/// Commands the fullscreen view sends back to the player. Built by `TuneNowPlayingHost`.
struct TuneNowPlayingActions {
    var previous: () -> Void = {}
    var playPause: () -> Void = {}
    var next: () -> Void = {}
    /// Seek to an absolute time in seconds.
    var seek: (TimeInterval) -> Void = { _ in }
    var toggleLike: () -> Void = {}
    var close: () -> Void = {}
    /// Cycles repeat off → all → one (the player's own cycle, same as the status line).
    var cycleRepeat: () -> Void = {}
    /// Shows or hides the Up Next pane.
    var toggleQueue: () -> Void = {}
    /// Plays the queue entry with this id.
    var playQueueEntry: (UUID) -> Void = { _ in }
    /// Moves the queue entry with this id right after the playing one.
    var playQueueEntryNext: (UUID) -> Void = { _ in }
    var removeQueueEntry: (UUID) -> Void = { _ in }
    /// Moves a queue entry before another entry (nil = end of the queue). Drag to reorder.
    var moveQueueEntry: (UUID, UUID?) -> Void = { _, _ in }
    /// Searches YouTube Music songs (debounced by the search model); empty clears.
    var search: (String) -> Void = { _ in }
    /// Plays the search result with this video id now (with its radio, like Search does).
    var playSearchResult: (String) -> Void = { _ in }
    var playSearchResultNext: (String) -> Void = { _ in }
    var addSearchResultToQueue: (String) -> Void = { _ in }
    /// Switches the search between Songs and Videos.
    var selectSearchFilter: (TuneNowPlayingSearchFilter) -> Void = { _ in }
    /// SONG · VIDEO: true shows the playing video in the artwork slot (when the track has one).
    var setPrefersVideo: (Bool) -> Void = { _ in }
}

// MARK: - TuneNowPlayingTransport

/// C2 `.foot`: glyph prev / play-pause / next, mono elapsed, thin scrubber, mono duration, like.
struct TuneNowPlayingTransport: View {
    let playback: TuneNowPlayingPlayback
    let actions: TuneNowPlayingActions
    /// Reports scrubbing so the parent keeps the transport visible mid-drag.
    var onScrubbingChanged: (Bool) -> Void = { _ in }
    /// Row width; beside lyrics it spans the text column so both share a right edge.
    var width: CGFloat = TuneTheme.NowPlaying.transportWidth
    /// Whether the Up Next pane is open (drives the QUEUE toggle).
    var isQueueShown = false
    /// SONG · VIDEO switch state.
    var video: TuneNowPlayingVideoToggle = .unavailable

    /// Fraction under the pointer while dragging the scrubber.
    @State private var dragFraction: Double?
    /// Target of the last seek, shown until the player's 1 Hz progress catches up.
    @State private var heldSeek: TimeInterval?

    /// Below this row width the text toggles move to their own line, so the scrubber keeps
    /// a usable length instead of shrinking to a dash beside them.
    static let singleRowMinWidth: CGFloat = 680

    var body: some View {
        Group {
            if self.width >= Self.singleRowMinWidth {
                HStack(spacing: TuneTheme.Spacing.itemGap) {
                    self.playbackControls
                    self.toggles
                }
            } else {
                VStack(alignment: .leading, spacing: TuneTheme.Spacing.unit * 2) {
                    HStack(spacing: TuneTheme.Spacing.itemGap) {
                        self.playbackControls
                    }
                    self.toggles
                }
            }
        }
        .frame(width: self.width, alignment: .leading)
        .onChange(of: self.playback.progress) { _, observed in
            if let heldSeek, abs(observed - heldSeek) < 2 {
                self.heldSeek = nil
            }
        }
        .task(id: self.heldSeek) {
            guard self.heldSeek != nil else { return }
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self.heldSeek = nil
        }
    }

    /// Glyphs, elapsed, scrubber, duration, like.
    @ViewBuilder
    private var playbackControls: some View {
        HStack(spacing: TuneTheme.Spacing.unit) {
            TuneGlyphButton(systemImage: "backward.end", label: Text("Previous"), action: self.actions.previous)
            TuneGlyphButton(
                systemImage: self.playback.isPlaying ? "pause" : "play",
                label: self.playback.isPlaying ? Text("Pause") : Text("Play"),
                action: self.actions.playPause
            )
            .accessibilityIdentifier(TuneNowPlayingAccessibilityID.playPauseButton)
            TuneGlyphButton(systemImage: "forward.end", label: Text("Next"), action: self.actions.next)
        }
        .padding(.leading, -TuneTheme.Spacing.unit * 1.5)

        Text(Self.format(self.displayedProgress))
            .font(TuneTheme.Typeface.data)
            .foregroundStyle(TuneTheme.Palette.ink)
            .accessibilityHidden(true)

        self.scrubber

        Text(Self.format(self.playback.duration))
            .font(TuneTheme.Typeface.data)
            .foregroundStyle(TuneTheme.Palette.inkMuted)
            .accessibilityHidden(true)

        if self.playback.canLike {
            TuneGlyphButton(
                systemImage: self.playback.isLiked ? "heart.fill" : "heart",
                label: self.playback.isLiked ? Text("Unlike") : Text("Like"),
                action: self.actions.toggleLike
            )
        }
    }

    /// SONG · VIDEO, REPEAT, QUEUE.
    private var toggles: some View {
        HStack(spacing: TuneTheme.Spacing.unit * 3) {
            TuneNowPlayingVideoSwitch(toggle: self.video, setPrefersVideo: self.actions.setPrefersVideo)

            let repeatState = TuneNowPlayingRepeatToggle(mode: self.playback.repeatMode)
            TuneNowPlayingTextToggle(
                title: Text(repeatState.title),
                isOn: repeatState.isOn,
                reservedTitle: Text(TuneNowPlayingRepeatToggle.widestTitle),
                action: self.actions.cycleRepeat
            )
            .help(Text("Repeat off, all, one (⌘R)"))
            .accessibilityLabel(Text("Repeat"))
            .accessibilityValue(Text(repeatState.accessibilityValue))
            .accessibilityIdentifier(TuneNowPlayingAccessibilityID.repeatToggle)

            TuneNowPlayingTextToggle(
                title: Text("Queue"),
                isOn: self.isQueueShown,
                action: self.actions.toggleQueue
            )
            .help(Text("Show or hide Up Next (⌥⌘U)"))
            .accessibilityValue(self.isQueueShown ? Text("Showing") : Text("Hidden"))
            .accessibilityIdentifier(TuneNowPlayingAccessibilityID.queueToggle)
        }
    }

    // MARK: Scrubber

    private var scrubber: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let fraction = self.displayedFraction
            let playhead = TuneTheme.NowPlaying.playheadSize
            let rail = TuneTheme.NowPlaying.scrubberHeight
            // The rail sits on the row's center line (with the glyphs and times); the tick
            // rises from the rail's bottom edge.
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: rail / 2, style: .continuous)
                    .fill(TuneTheme.Palette.ink.opacity(0.18))
                    .frame(height: rail)
                RoundedRectangle(cornerRadius: rail / 2, style: .continuous)
                    .fill(TuneTheme.Palette.inkSecondary)
                    .frame(width: width * fraction, height: rail)
                RoundedRectangle(cornerRadius: playhead.width / 2, style: .continuous)
                    .fill(TuneTheme.Palette.accent)
                    .frame(width: playhead.width, height: playhead.height)
                    .offset(
                        x: min(max(width * fraction - playhead.width / 2, 0), width - playhead.width),
                        y: -(playhead.height - rail) / 2
                    )
            }
            .frame(width: width)
            .frame(maxHeight: .infinity)
            .contentShape(.rect)
            .gesture(self.scrubGesture(width: width), including: self.playback.canSeek ? .all : .none)
        }
        .frame(height: TuneTheme.NowPlaying.scrubberHitHeight)
        .frame(maxWidth: .infinity)
        .accessibilityElement()
        .accessibilityLabel(Text("Playback position"))
        .accessibilityValue(Text(verbatim: "\(Self.format(self.displayedProgress)) / \(Self.format(self.playback.duration))"))
        .accessibilityAdjustableAction { direction in
            guard self.playback.canSeek else { return }
            let step: TimeInterval = direction == .increment ? 10 : -10
            self.commitSeek(to: self.displayedProgress + step)
        }
        .accessibilityIdentifier(TuneNowPlayingAccessibilityID.scrubber)
    }

    private func scrubGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if self.dragFraction == nil {
                    self.onScrubbingChanged(true)
                }
                self.dragFraction = Self.fraction(x: value.location.x, width: width)
            }
            .onEnded { value in
                let fraction = Self.fraction(x: value.location.x, width: width)
                self.dragFraction = nil
                self.onScrubbingChanged(false)
                self.commitSeek(to: fraction * self.playback.duration)
            }
    }

    private func commitSeek(to time: TimeInterval) {
        guard self.playback.canSeek, self.playback.duration > 0, time.isFinite else { return }
        let target = min(max(time, 0), self.playback.duration)
        self.heldSeek = target
        self.actions.seek(target)
    }

    // MARK: Derived

    private var displayedProgress: TimeInterval {
        if let dragFraction {
            return dragFraction * self.playback.duration
        }
        return self.heldSeek ?? self.playback.clampedProgress
    }

    private var displayedFraction: Double {
        guard self.playback.duration > 0 else { return 0 }
        return min(max(self.displayedProgress / self.playback.duration, 0), 1)
    }

    static func fraction(x: CGFloat, width: CGFloat) -> Double {
        guard width > 0, x.isFinite else { return 0 }
        return Double(min(max(x / width, 0), 1))
    }

    /// `m:ss`, or `h:mm:ss` past an hour. Non-finite or negative input reads `0:00`.
    static func format(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}

// MARK: - TuneGlyphButton

/// A bare glyph: no fill, no circle, ink on hover.
struct TuneGlyphButton: View {
    let systemImage: String
    let label: Text
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: self.action) {
            Image(systemName: self.systemImage)
                .font(TuneTheme.Typeface.body)
                .foregroundStyle(self.isHovered ? TuneTheme.Palette.ink : TuneTheme.Palette.inkSecondary)
                .frame(width: TuneTheme.NowPlaying.controlHitSize, height: TuneTheme.NowPlaying.controlHitSize)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { self.isHovered = $0 }
        .accessibilityLabel(self.label)
    }
}

// MARK: - TuneNowPlayingTextToggle

/// C2 `.tog` for the fullscreen transport: uppercase tracked text, ink with a 1 pt underline
/// when on, muted when off. No fill, no pill.
struct TuneNowPlayingTextToggle: View {
    let title: Text
    let isOn: Bool
    /// The longest label this toggle cycles through; reserves its width so the row doesn't shift.
    var reservedTitle: Text?
    /// Off: inkDim, no underline, inert (e.g. VIDEO for a track without one).
    var isEnabled = true
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: self.action) {
            ZStack(alignment: .leading) {
                if let reservedTitle {
                    Self.caps(reservedTitle)
                        .hidden()
                }
                Self.caps(self.title)
                    .foregroundStyle(self.inkColor)
                    .padding(.bottom, 1)
                    .overlay(alignment: .bottom) {
                        if self.isOn, self.isEnabled {
                            Rectangle()
                                .fill(TuneTheme.Palette.ink)
                                .frame(height: 1)
                                .offset(y: 1)
                        }
                    }
            }
                .frame(height: TuneTheme.NowPlaying.controlHitSize)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .disabled(!self.isEnabled)
        .onHover { self.isHovered = $0 }
        .accessibilityAddTraits(self.isOn ? .isSelected : [])
    }

    private static func caps(_ text: Text) -> some View {
        text
            .font(TuneTheme.Typeface.label)
            .tracking(0.9)
            .textCase(.uppercase)
            .lineLimit(1)
            .fixedSize()
    }

    private var inkColor: Color {
        if !self.isEnabled {
            return TuneTheme.Palette.inkDim
        }
        if self.isOn {
            return TuneTheme.Palette.ink
        }
        return self.isHovered ? TuneTheme.Palette.inkSecondary : TuneTheme.Palette.inkMuted
    }
}

// MARK: - TuneNowPlayingRepeatToggle

/// What the REPEAT toggle shows for a repeat mode: ink "REPEAT" for all, ink "REPEAT 1" for
/// one, muted "REPEAT" when off. Never the accent — repeat is a setting, not playback state.
struct TuneNowPlayingRepeatToggle: Equatable {
    let mode: PlayerService.RepeatMode

    static var widestTitle: LocalizedStringKey {
        "Repeat 1"
    }

    var title: LocalizedStringKey {
        self.mode == .one ? "Repeat 1" : "Repeat"
    }

    var isOn: Bool {
        self.mode != .off
    }

    var accessibilityValue: LocalizedStringKey {
        switch self.mode {
        case .off: "Off"
        case .all: "All"
        case .one: "One"
        }
    }
}

// MARK: - TuneNowPlayingAccessibilityID

enum TuneNowPlayingAccessibilityID {
    static let root = "tuneNowPlaying"
    static let playPauseButton = "tuneNowPlaying.playPause"
    static let scrubber = "tuneNowPlaying.scrubber"
    static let lyrics = "tuneNowPlaying.lyrics"
    static let closeButton = "tuneNowPlaying.close"
    static let queuePanel = "tuneNowPlaying.queue"
    static let queueToggle = "tuneNowPlaying.queueToggle"
    static let repeatToggle = "tuneNowPlaying.repeatToggle"
    static let videoToggle = "tuneNowPlaying.videoToggle"
    static let videoSlot = "tuneNowPlaying.video"
    static let searchFilter = "tuneNowPlaying.searchFilter"
    static let searchField = "tuneNowPlaying.search"
    static let searchResults = "tuneNowPlaying.searchResults"
}
