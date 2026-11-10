import Foundation

// MARK: - SongTransitionSettings

/// User-facing song transition preferences (Settings → Music → Song Transitions).
///
/// With crossfade on, the next song starts playing during the last `crossfadeSeconds` of
/// the current one in a short-lived second page (the crossfade deck, ADR-0044). When the
/// deck cannot be used, the outgoing song fades out and the next song fades in on the one
/// playback element instead (ADR-0043). Both are gain multipliers over the user's volume.
struct SongTransitionSettings: Equatable {
    /// Allowed crossfade lengths in whole seconds; 0 turns track-end fades off.
    static let crossfadeRange = 0 ... 12
    static let off = SongTransitionSettings(crossfadeSeconds: 0, fadesTransportControls: false)

    /// Seconds of fade at the end of each song (0 = off), clamped to `crossfadeRange`.
    let crossfadeSeconds: Int
    /// Whether manual pause, resume and skip get a short fade.
    let fadesTransportControls: Bool

    init(crossfadeSeconds: Int, fadesTransportControls: Bool) {
        self.crossfadeSeconds = Self.clampedCrossfadeSeconds(crossfadeSeconds)
        self.fadesTransportControls = fadesTransportControls
    }

    var isCrossfadeEnabled: Bool {
        self.crossfadeSeconds > 0
    }

    static func clampedCrossfadeSeconds(_ value: Int) -> Int {
        min(max(value, Self.crossfadeRange.lowerBound), Self.crossfadeRange.upperBound)
    }
}

// MARK: - SongTransitionTiming

/// Fixed timings for transport fades. Kept short so controls still feel immediate.
enum SongTransitionTiming {
    /// Fade-out before a manual pause or skip.
    static let transportFadeOutMilliseconds = 300
    /// Fade-in after a manual resume.
    static let resumeFadeInMilliseconds = 350
    /// Fade-in of the next song after a manual skip.
    static let skipFadeInMilliseconds = 450
    /// The next song's fade-in (single-element transition) never exceeds this, so its
    /// opening is not lost and the hand-over never sounds like a gap.
    static let maximumFadeInSeconds = 1.5
    /// Track-end fades only run on songs longer than this multiple of the crossfade.
    static let minimumTrackLengthMultiple = 3
}

// MARK: - CrossfadeTiming

/// Timings for the true (two-page) crossfade. See `docs/adr/0044-crossfade-deck.md`.
enum CrossfadeTiming {
    /// The deck page is created this long before the crossfade starts. A cold deck measured
    /// 1.3–1.5 s from creation to playable, so this leaves room for a slow network while
    /// keeping the deck's extra WebContent process alive for as short a time as possible.
    static let deckLeadSeconds: Double = 6
    /// The deck's fade-in never runs shorter than this, even when a seek lands in the
    /// last moments of a song (the outgoing song then fades over what is left).
    static let minimumDeckFadeSeconds: Double = 1.5
    /// A deck still loading by this point stops holding the song at full volume: it fades
    /// over what is left and the deck starts late (as soon as it is ready).
    static let pendingGiveUpRemainingSeconds: Double = 1.0
    /// Fade-in of a deck that starts late, after the outgoing song already ended.
    static let lateStartFadeSeconds: Double = 0.3
    /// A late deck that is still not playable after this long is abandoned.
    static let lateGiveUpMilliseconds = 6000
    /// Shortest overlap a seek into the last seconds still gets.
    static let minimumOverlapSeconds: Double = 1.5
    /// Extra room for a deck that is not loaded yet when a seek lands near the end.
    static let deckLoadAllowanceSeconds: Double = 1.5
    /// The handoff keeps trying to line the main player up with the deck for this long,
    /// then fades between them from wherever they are.
    static let handoffGiveUpMilliseconds = 8000
    /// Equal-power swap from the deck back to the main player once they are in sync.
    static let swapMilliseconds = 150
    /// The two clocks must agree to within this before the swap. Alignment is by seek
    /// only (rate nudging made WebKit's time-pitch stretcher crackle afterwards), so
    /// allow what a learned-latency seek reliably reaches; inaudible across a 150 ms swap.
    static let syncToleranceSeconds: Double = 0.04
    /// Longest overlap for Next pressed while the deck is ready.
    static let maximumQuickOverlapMilliseconds = 2000
    /// A crossfade that has not finished this long after it started is torn down.
    static let sessionHardLimitSeconds: Double = 25

    static func quickOverlapMilliseconds(crossfadeSeconds: Int) -> Int {
        min(max(crossfadeSeconds, 0) * 1000, Self.maximumQuickOverlapMilliseconds)
    }

    /// Where a seek near a song's end lands so the crossfade still has room: never
    /// later than `minimumOverlapSeconds` before the end (plus the deck's load time when
    /// it is not ready yet). Earlier seeks, and songs too short for this, are unchanged.
    static func seekTarget(_ time: Double, duration: Double, isDeckReady: Bool) -> Double {
        guard time.isFinite, duration.isFinite, duration > 0 else { return time }
        let lead = Self.minimumOverlapSeconds + (isDeckReady ? 0 : Self.deckLoadAllowanceSeconds)
        guard duration > lead * 2, time > duration - lead else { return time }
        return duration - lead
    }
}

// MARK: - CrossfadeHandoff

/// An in-flight crossfade carried into a fresh main-page document (full-page navigation).
struct CrossfadeHandoff: Equatable {
    let token: Int
    let videoId: String
    let channelToken: Int
    /// Wall-clock milliseconds after which a new document ignores it.
    let expiresAtMilliseconds: Double

    /// Overlap spec literal for the page engine, or nil when `videoId` is not a video id.
    var literal: String? {
        Self.specLiteral(token: self.token, videoId: self.videoId, channelToken: self.channelToken, expiresAt: self.expiresAtMilliseconds)
    }

    static func specLiteral(token: Int, videoId: String, channelToken: Int, expiresAt: Double? = nil) -> String? {
        guard CrossfadeDeckScript.isValidVideoId(videoId) else { return nil }
        let clampedToken = min(max(token, 0), Int(Int32.max))
        var literal = "{ token: \(clampedToken), videoId: '\(videoId)', channel: '\(CrossfadeDeckScript.channelName(token: channelToken))'"
        if let expiresAt, expiresAt.isFinite {
            literal += ", expiresAt: \(Int64(expiresAt.rounded()))"
        }
        return literal + " }"
    }
}

// MARK: - SongTransitionCommand

/// The only commands Swift sends to the page-side transition engine.
///
/// Scripts are built from validated integers and booleans only; nothing from the
/// page or the network is interpolated.
enum SongTransitionCommand: Equatable {
    case configure(SongTransitionSettings)
    /// Fades the current song out; `fadeInMilliseconds > 0` also arms a fade-in for the next media.
    case fadeOut(token: Int, milliseconds: Int, fadeInMilliseconds: Int)
    /// The Swift operation behind `token` finished (or, when `superseded`, was dropped
    /// because a newer intent won); recover the gain if it is still held low.
    case release(token: Int, superseded: Bool)
    /// Starts the next play at zero gain and ramps it up.
    case fadeInOnPlay(milliseconds: Int)
    /// The crossfade deck is loading `videoId` for this song's end.
    case prepareOverlap(token: Int, videoId: String, channelToken: Int)
    /// The deck has `videoId` buffered; the overlap starts with this song's tail.
    case armOverlap(token: Int)
    /// Next pressed with the deck ready: overlap for `milliseconds`, then skip.
    case quickOverlap(token: Int, milliseconds: Int)
    /// Stops any overlap (nil: whichever is active).
    case cancelOverlap(token: Int?)

    /// Upper bound for any millisecond argument (keeps literals small and finite).
    static let maximumMilliseconds = 5000

    var script: String {
        let call = switch self {
        case let .configure(settings):
            "configure(\(Self.configLiteral(settings)))"
        case let .fadeOut(token, milliseconds, fadeInMilliseconds):
            "fadeOut(\(Self.token(token)), \(Self.milliseconds(milliseconds)), \(Self.milliseconds(fadeInMilliseconds)))"
        case let .release(token, superseded):
            "release(\(Self.token(token)), \(superseded ? "true" : "false"))"
        case let .fadeInOnPlay(milliseconds):
            "fadeInOnPlay(\(Self.milliseconds(milliseconds)))"
        case let .prepareOverlap(token, videoId, channelToken):
            CrossfadeHandoff.specLiteral(token: token, videoId: videoId, channelToken: channelToken)
                .map { "prepareOverlap(\($0))" } ?? "overlapState()"
        case let .armOverlap(token):
            "armOverlap(\(Self.token(token)))"
        case let .quickOverlap(token, milliseconds):
            "quickOverlap(\(Self.token(token)), \(Self.milliseconds(milliseconds)))"
        case let .cancelOverlap(token):
            "cancelOverlap(\(token.map { String(Self.token($0)) } ?? "null"))"
        }
        return "if (window.__kasetSongTransitions) { window.__kasetSongTransitions.\(call); }"
    }

    static func configLiteral(_ settings: SongTransitionSettings) -> String {
        let seconds = SongTransitionSettings.clampedCrossfadeSeconds(settings.crossfadeSeconds)
        let transport = settings.fadesTransportControls ? "true" : "false"
        return "{ crossfadeSeconds: \(seconds), fadesTransportControls: \(transport) }"
    }

    private static func token(_ value: Int) -> Int {
        min(max(value, 0), Int(Int32.max))
    }

    private static func milliseconds(_ value: Int) -> Int {
        min(max(value, 0), Self.maximumMilliseconds)
    }
}
