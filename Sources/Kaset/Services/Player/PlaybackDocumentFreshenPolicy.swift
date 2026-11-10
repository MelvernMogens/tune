import Foundation

// MARK: - PlaybackDocumentFreshenPolicy

/// Pure decision logic for replacing the hidden YouTube Music page while the listener is
/// away, so its WebContent process does not keep growing for the life of the app.
///
/// The playback page is a long-lived single-page app. Its JavaScript heap and WebKit
/// malloc grow over hours of listening (measured 480 MB → 900 MB footprint), and a
/// router navigation never releases it. Rebuilding the WebView drops that page — and
/// usually its whole WebContent process — but it must never be audible. So a freshen
/// only happens after the listener explicitly paused and left it paused for a while,
/// and only when nothing could be visibly interrupted (video, AirPlay, ads, an
/// in-flight load or native queue handoff). Afterwards playback is in exactly the
/// state a cold launch restores: the track stays selected at its position, and the
/// next Play loads it into a fresh page and seeks back.
///
/// The type performs no I/O; ``PlayerService`` builds a ``Snapshot`` and performs the
/// freshen when ``decide(_:)`` says so, which keeps every decision unit-testable.
struct PlaybackDocumentFreshenPolicy: Equatable {
    /// A page younger than this is left alone: it has not grown enough to be worth the
    /// slower first Play (a full page load instead of an instant resume).
    var minimumDocumentAge: Duration = .seconds(60 * 60)
    /// How long playback must stay explicitly paused before the page is replaced.
    var minimumPausedDuration: Duration = .seconds(15 * 60)

    static let `default` = PlaybackDocumentFreshenPolicy()

    struct Snapshot: Equatable {
        /// Native transport is `.paused` and the listener (not Kaset or the system) paused it.
        var isExplicitlyPaused: Bool
        /// How long the explicit pause has lasted so far.
        var pausedDuration: Duration
        /// Age of the current playback WebView; nil when there is none.
        var documentAge: Duration?
        var hasCurrentTrack: Bool
        /// A restored session is already deferred (nothing loaded) — there is nothing to free.
        var isLoadDeferred: Bool
        /// A load, restore, native queue handoff, or queue maintenance is in flight.
        var isTransitioning: Bool
        /// The video window, mini-player toast, or Now Playing video shows the page.
        var isVideoVisible: Bool
        var isAirPlayConnected: Bool
        var isShowingAd: Bool
    }

    enum Decision: Equatable {
        /// Rebuild the playback page now.
        case freshen
        /// Eligible except for time; check again after this delay.
        case wait(Duration)
        /// Not eligible in the current state; wait for the state to change.
        case ineligible
    }

    func decide(_ snapshot: Snapshot) -> Decision {
        guard snapshot.isExplicitlyPaused,
              snapshot.hasCurrentTrack,
              !snapshot.isLoadDeferred,
              !snapshot.isTransitioning,
              !snapshot.isVideoVisible,
              !snapshot.isAirPlayConnected,
              !snapshot.isShowingAd,
              let documentAge = snapshot.documentAge
        else { return .ineligible }

        let pausedRemaining = self.minimumPausedDuration - snapshot.pausedDuration
        let ageRemaining = self.minimumDocumentAge - documentAge
        let remaining = max(pausedRemaining, ageRemaining)
        if remaining > .zero {
            return .wait(remaining)
        }
        return .freshen
    }
}
