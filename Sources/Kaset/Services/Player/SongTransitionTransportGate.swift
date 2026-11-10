import Foundation

// MARK: - SongTransitionTransportGate

/// Runs user transport commands (pause, skip) behind a short fade-out.
///
/// The fade is cosmetic: the command always runs (it is dropped only when a newer
/// playback intent superseded it during the fade), and every fade-out is followed
/// by a `release`, so the page can never be left holding a low gain.
///
/// Ordering: a command that arrives while a fade is in flight cuts that fade short
/// and runs right after the first command has started, so two quick Next presses
/// still skip twice, in order.
@MainActor
final class SongTransitionTransportGate {
    enum Kind: Equatable {
        case pause
        case skip

        /// Fade-in armed for the next media (skips only).
        var fadeInMilliseconds: Int {
            switch self {
            case .pause: 0
            case .skip: SongTransitionTiming.skipFadeInMilliseconds
            }
        }
    }

    @MainActor
    private final class ActiveFade {
        let token: Int
        var sleeper: Task<Void, Never>?
        var waiters: [CheckedContinuation<Void, Never>] = []

        init(token: Int) {
            self.token = token
        }
    }

    private let send: @MainActor (SongTransitionCommand) -> Void
    private let fadeDuration: Duration
    private var activeFade: ActiveFade?
    private var nextToken = 1

    init(
        fadeDuration: Duration = .milliseconds(SongTransitionTiming.transportFadeOutMilliseconds),
        send: @escaping @MainActor (SongTransitionCommand) -> Void
    ) {
        self.fadeDuration = fadeDuration
        self.send = send
    }

    /// Whether a transport fade is currently in flight.
    var isFading: Bool {
        self.activeFade != nil
    }

    /// Commands queued behind the in-flight fade.
    var waitingCommandCount: Int {
        self.activeFade?.waiters.count ?? 0
    }

    /// A true crossfade into the next song (the deck already holds it): the page has
    /// started it; `body` (the skip) runs once it has played for `milliseconds`.
    struct QuickOverlap {
        let milliseconds: Int
        /// Stops the overlap when the skip was dropped for a newer intent.
        let cancel: @MainActor () -> Void
    }

    /// Fades out when `canFade`, then runs `body`.
    ///
    /// - Parameters:
    ///   - canFade: Setting on and music audibly playing (no ad, no AirPlay).
    ///   - intentGeneration: Changes whenever a new playback intent begins; `body`
    ///     is skipped if it changed during the fade (the user already moved on).
    func perform(
        _ kind: Kind,
        canFade: Bool,
        quickOverlap: QuickOverlap? = nil,
        intentGeneration: @MainActor () -> UInt64,
        _ body: @MainActor () async -> Void
    ) async {
        if let activeFade = self.activeFade {
            // Hurry the in-flight fade and run after its command has started.
            activeFade.sleeper?.cancel()
            await withCheckedContinuation { continuation in
                activeFade.waiters.append(continuation)
            }
            await body()
            return
        }

        guard canFade || quickOverlap != nil else {
            await body()
            return
        }

        let fade = ActiveFade(token: self.makeToken())
        self.activeFade = fade
        let generationBeforeFade = intentGeneration()
        let duration: Duration
        if let quickOverlap {
            duration = .milliseconds(quickOverlap.milliseconds)
        } else {
            self.send(.fadeOut(
                token: fade.token,
                milliseconds: self.fadeMilliseconds,
                fadeInMilliseconds: kind.fadeInMilliseconds
            ))
            duration = self.fadeDuration
        }

        let sleeper = Task { @MainActor in
            do {
                try await Task.sleep(for: duration)
            } catch {
                // Cancelled: a newer transport command cut the fade short.
            }
        }
        fade.sleeper = sleeper
        await sleeper.value

        self.activeFade = nil
        let waiters = fade.waiters
        fade.waiters.removeAll()
        // Resumed waiters run once this task next suspends, i.e. after `body` has
        // begun its playback intent, so their commands follow ours.
        for waiter in waiters {
            waiter.resume()
        }

        let isCurrent = intentGeneration() == generationBeforeFade
        if isCurrent {
            await body()
        }
        if let quickOverlap {
            if !isCurrent { quickOverlap.cancel() }
        } else {
            self.send(.release(token: fade.token, superseded: !isCurrent))
        }
    }

    /// Requests a fade-in for the next play when resuming paused music, or — when a
    /// resume interrupts an in-flight fade-out — ramps straight back up from there.
    func prepareResume(canFade: Bool) {
        guard canFade || self.activeFade != nil else { return }
        self.send(.fadeInOnPlay(milliseconds: SongTransitionTiming.resumeFadeInMilliseconds))
    }

    /// The page fade matches the Swift wait exactly.
    private var fadeMilliseconds: Int {
        let components = self.fadeDuration.components
        let milliseconds = Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
        guard milliseconds.isFinite else { return SongTransitionTiming.transportFadeOutMilliseconds }
        return Int(min(max(milliseconds.rounded(), 0), Double(SongTransitionCommand.maximumMilliseconds)))
    }

    private func makeToken() -> Int {
        let token = self.nextToken
        self.nextToken = self.nextToken >= Int(Int32.max) ? 1 : self.nextToken + 1
        return token
    }
}
