import WebKit

// MARK: - SingletonPlayerWebView Idle Prompt Guard

extension SingletonPlayerWebView {
    /// Keeps YouTube Music's "Are you still listening?" idle prompt from pausing
    /// Kaset-driven playback.
    ///
    /// YouTube Music arms the prompt from `configData.youThereData` in the player
    /// response, then compares `lactThresholdMs` against the page's last-activity
    /// clock, `window._lact` (`Date.now() - _lact`). That clock only advances on DOM
    /// keyboard/mouse/touch/scroll events. Kaset plays from a hidden 1×1 WebView that
    /// never receives those events, so once a listening session outlives the threshold
    /// the page pauses the `<video>` and opens a modal with nobody to answer it. The
    /// `ended` event never fires for the paused song, so Kaset's queue does not advance.
    ///
    /// Every interaction with Kaset's native UI is real listener activity. This script
    /// refreshes the page activity clock while Kaset intends playback and, as a
    /// fallback, answers a visible prompt and resumes playback if YouTube Music still
    /// opens it. It never resumes media that Kaset paused or suppressed
    /// (`__kasetPlaybackSuppressed` / `__kasetBlockAutoplay`), and it only refreshes a
    /// clock YouTube Music already initialized so its own activity listeners still
    /// install normally.
    nonisolated static var idlePromptGuardScript: String {
        """
        (function() {
            'use strict';
            if (window.__kasetIdlePromptGuardInstalled) return;
            window.__kasetIdlePromptGuardInstalled = true;
            const ACTIVITY_REFRESH_INTERVAL_MS = 60000;
            const MEDIA_ACTIVITY_THROTTLE_MS = 30000;
            const PROMPT_RETRY_MS = 5000;
            let lastMediaActivityRefresh = 0;

            function kasetWantsPlayback() {
                return !window.__kasetPlaybackSuppressed && !window.__kasetBlockAutoplay;
            }

            function refreshActivityClock() {
                if (!kasetWantsPlayback()) return false;
                try {
                    if (typeof window._lact !== 'number') return false;
                    window._lact = Date.now();
                    return true;
                } catch (_) {
                    return false;
                }
            }

            function refreshFromMediaEvent(event) {
                const target = event && event.target;
                if (!target || target.tagName !== 'VIDEO') return;
                const now = Date.now();
                if (event.type === 'timeupdate'
                    && now - lastMediaActivityRefresh < MEDIA_ACTIVITY_THROTTLE_MS) return;
                lastMediaActivityRefresh = now;
                refreshActivityClock();
            }

            function isPromptVisible(renderer) {
                if (!renderer || renderer.isConnected === false) return false;
                const dialog = renderer.closest ? renderer.closest('tp-yt-paper-dialog') : null;
                const host = dialog || renderer;
                if (host.opened === false) return false;
                if (host.hidden === true) return false;
                try {
                    const style = typeof getComputedStyle === 'function' ? getComputedStyle(host) : null;
                    if (style && (style.display === 'none' || style.visibility === 'hidden')) return false;
                } catch (_) {}
                return true;
            }

            function dismissYouThereDialog() {
                if (!kasetWantsPlayback()) return false;
                const renderer = document.querySelector('ytmusic-you-there-renderer');
                if (!renderer) return false;
                if (!isPromptVisible(renderer)) {
                    // A closed prompt can stay in the DOM; forget it so a reopened one is answered.
                    renderer.__kasetPromptAnsweredAt = 0;
                    return false;
                }
                const now = Date.now();
                if (now - (renderer.__kasetPromptAnsweredAt || 0) < PROMPT_RETRY_MS) return false;
                renderer.__kasetPromptAnsweredAt = now;
                refreshActivityClock();
                // The renderer's template has a single `dialog-confirm` action ("Yes").
                const confirm = renderer.querySelector('yt-button-renderer[dialog-confirm] button')
                    || renderer.querySelector('yt-button-renderer[dialog-confirm]')
                    || renderer.querySelector('yt-button-renderer button');
                if (confirm && typeof confirm.click === 'function') {
                    confirm.click();
                } else {
                    const dialog = renderer.closest ? renderer.closest('tp-yt-paper-dialog') : null;
                    if (dialog && typeof dialog.close === 'function') dialog.close();
                }
                const video = document.querySelector('video');
                if (video && video.paused && !video.ended && kasetWantsPlayback()) {
                    try {
                        const result = video.play();
                        if (result && typeof result.catch === 'function') result.catch(() => {});
                    } catch (_) {}
                }
                return true;
            }

            window.__kasetRefreshPageActivity = refreshActivityClock;
            window.__kasetDismissIdlePrompt = dismissYouThereDialog;
            refreshActivityClock();
            setInterval(refreshActivityClock, ACTIVITY_REFRESH_INTERVAL_MS);
            // Hidden-page timers are throttled; media events keep firing while audible.
            document.addEventListener('play', refreshFromMediaEvent, true);
            document.addEventListener('playing', refreshFromMediaEvent, true);
            document.addEventListener('ended', refreshFromMediaEvent, true);
            document.addEventListener('timeupdate', refreshFromMediaEvent, true);

            function observeDialogs() {
                const target = document.body || document.documentElement;
                if (!target || typeof MutationObserver !== 'function') return;
                let pending = false;
                const observer = new MutationObserver(() => {
                    if (pending) return;
                    pending = true;
                    setTimeout(() => {
                        pending = false;
                        dismissYouThereDialog();
                    }, 250);
                });
                // Reopening a mounted dialog toggles `opened` without adding nodes.
                observer.observe(target, {
                    childList: true,
                    subtree: true,
                    attributes: true,
                    attributeFilter: ['opened']
                });
            }

            if (document.readyState === 'loading') {
                document.addEventListener('DOMContentLoaded', observeDialogs);
            } else {
                observeDialogs();
            }
        })();
        """
    }

    /// The idle-prompt guard as installed into every playback document.
    static func makeIdlePromptGuardUserScript() -> WKUserScript {
        WKUserScript(
            source: Self.idlePromptGuardScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
    }

    /// Refreshes the page activity clock and answers a visible idle prompt.
    /// The prompt path resumes media only while the page-side playback intent
    /// flags still allow playback, so it never overrides a Kaset pause.
    func refreshPageActivity() {
        guard let webView else { return }
        let generation = self.documentGeneration.currentGeneration
        guard self.documentGeneration.accepts(generation: generation) else { return }
        webView.evaluateJavaScript("""
            if (window.__kasetDocumentGeneration === \(generation)) {
                if (typeof window.__kasetRefreshPageActivity === 'function') window.__kasetRefreshPageActivity();
                if (typeof window.__kasetDismissIdlePrompt === 'function') window.__kasetDismissIdlePrompt();
            }
            void 0;
        """, completionHandler: nil)
    }
}
