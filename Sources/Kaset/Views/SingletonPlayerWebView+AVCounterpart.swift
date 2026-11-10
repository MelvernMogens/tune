import Foundation

// MARK: - SingletonPlayerWebView AV Counterpart

/// YouTube Music's own Song / Video switch.
///
/// A song (`MUSIC_VIDEO_TYPE_ATV`) streams audio only — its `<video>` reports a 0×0 frame —
/// so showing the playback WebView for a song is a black rectangle. When the signed-in queue
/// pairs the song with a music video, YouTube Music's `next` response wraps the queue item
/// (`playlistPanelVideoWrapperRenderer`) with a `counterpart` and a `segmentMap`, and the page's
/// `ytmusic-av-toggle` swaps the same `<video>` element to the counterpart's video id at the
/// mapped position (and back). Setting `ytmusic-player-page.videoMode` does not: the page
/// recomputes it at once, so the audio-only stream stays.
///
/// While the counterpart plays, the page reports the counterpart's id, title and thumbnail.
/// Kaset's queue still owns the song, so every bridge reading the page's video id maps a
/// counterpart back to its primary (`__kasetCanonicalVideoId`) — a swap is never a new track.
extension SingletonPlayerWebView {
    /// Shared helpers: counterpart → primary id mapping and the current item's video availability.
    /// Installed by the observer script; also published on `window` for other bridges.
    nonisolated static var avCounterpartFunctionJS: String {
        """
        function __kasetWrapperPrimaryVideoId(data) {
            const primary = data && data.primaryRenderer && data.primaryRenderer.playlistPanelVideoRenderer;
            return primary && typeof primary.videoId === 'string' ? primary.videoId : '';
        }

        function __kasetWrapperHasCounterpart(data, videoId) {
            if (!data || !Array.isArray(data.counterpart)) return false;
            for (const entry of data.counterpart) {
                const renderer = entry && entry.counterpartRenderer
                    && entry.counterpartRenderer.playlistPanelVideoRenderer;
                if (renderer && renderer.videoId === videoId) return true;
            }
            return false;
        }

        function __kasetCounterpartPrimaryVideoId(videoId) {
            if (typeof videoId !== 'string' || !videoId) return '';
            let primaryForCounterpart = '';
            try {
                const wrappers = document.querySelectorAll('ytmusic-playlist-panel-video-wrapper-renderer');
                // The playing entry's own pairing decides first, so a queue that also lists
                // the music video as a separate entry can't steal the identity.
                for (let index = 0; index < wrappers.length; index += 1) {
                    const wrapper = wrappers[index];
                    if (!wrapper || typeof wrapper.querySelector !== 'function'
                        || !wrapper.querySelector('ytmusic-player-queue-item[selected]')) continue;
                    const data = wrapper.data;
                    const primaryVideoId = __kasetWrapperPrimaryVideoId(data);
                    if (primaryVideoId && primaryVideoId !== videoId && __kasetWrapperHasCounterpart(data, videoId)) {
                        return primaryVideoId;
                    }
                    break;
                }
                for (let index = 0; index < wrappers.length; index += 1) {
                    const data = wrappers[index] && wrappers[index].data;
                    if (!data || typeof data !== 'object') continue;
                    const primaryVideoId = __kasetWrapperPrimaryVideoId(data);
                    if (!primaryVideoId) continue;
                    // Otherwise a queue entry that is itself this video wins over a pairing.
                    if (primaryVideoId === videoId) return '';
                    if (!primaryForCounterpart && __kasetWrapperHasCounterpart(data, videoId)) {
                        primaryForCounterpart = primaryVideoId;
                    }
                }
            } catch (e) {
                return '';
            }
            return primaryForCounterpart;
        }

        function __kasetCanonicalVideoId(videoId) {
            const primary = __kasetCounterpartPrimaryVideoId(videoId);
            return primary || videoId;
        }
        window.__kasetCanonicalVideoId = __kasetCanonicalVideoId;

        function __kasetCurrentItemHasVideo() {
            try {
                const toggle = document.querySelector('ytmusic-av-toggle');
                if (toggle && toggle.hasAttribute('selected-queue-item-has-counterpart')) return true;
                const video = document.querySelector('video');
                return !!(video && Number(video.videoWidth) > 0 && Number(video.videoHeight) > 0);
            } catch (e) {
                return false;
            }
        }
        """
    }

    /// Switches the page to the playing song's music video through YouTube Music's own toggle.
    ///
    /// Statuses: `switched` (the page is swapping to the counterpart), `alreadyVideo`,
    /// `mediaHasVideo` (the item itself is a video), `noCounterpart` (audio only — nothing to show).
    nonisolated static var switchToVideoScript: String {
        """
        (function() {
            const toggle = document.querySelector('ytmusic-av-toggle');
            const video = document.querySelector('video');
            const mediaHasVideo = !!(video && Number(video.videoWidth) > 0 && Number(video.videoHeight) > 0);
            if (toggle) {
                const videoButton = toggle.querySelector('.video-button');
                const videoSelected = toggle.getAttribute('playback-mode') === 'OMV_PREFERRED'
                    || toggle.getAttribute('is-video-playback-mode-selected') === 'true'
                    || (videoButton && videoButton.getAttribute('aria-pressed') === 'true');
                const hasCounterpart = toggle.hasAttribute('selected-queue-item-has-counterpart');
                if (hasCounterpart && videoSelected) return { status: 'alreadyVideo' };
                if (hasCounterpart && videoButton) {
                    videoButton.click();
                    return { status: 'switched' };
                }
            }
            return { status: mediaHasVideo ? 'mediaHasVideo' : 'noCounterpart' };
        })();
        """
    }

    /// Returns the page to Song (audio only) after Kaset switched it to Video, exactly like
    /// picking Song in YouTube Music — it swaps back at the mapped position.
    nonisolated static var restoreSongScript: String {
        """
        (function() {
            const toggle = document.querySelector('ytmusic-av-toggle');
            if (!toggle) return { status: 'noToggle' };
            if (toggle.getAttribute('playback-mode') !== 'OMV_PREFERRED') return { status: 'alreadySong' };
            const songButton = toggle.querySelector('.song-button');
            if (!songButton) return { status: 'noToggle' };
            songButton.click();
            return { status: 'restored' };
        })();
        """
    }

    /// What the switch script reported.
    enum AVSwitchStatus: String, Equatable {
        case switched
        case alreadyVideo
        case mediaHasVideo
        case noCounterpart

        nonisolated init?(scriptResult: Any?) {
            guard let dictionary = scriptResult as? [String: Any],
                  let status = dictionary["status"] as? String
            else { return nil }
            self.init(rawValue: status)
        }

        /// Whether Kaset changed the page's Song/Video preference and must hand it back.
        nonisolated var pageNeedsSongRestore: Bool {
            self == .switched
        }
    }

    /// Asks the page to play the song's music video. Remembers a switch Kaset made so leaving
    /// video mode can give the page its Song preference back.
    func switchPageToVideo(completion: @escaping @MainActor (AVSwitchStatus?) -> Void) {
        guard let webView else {
            completion(nil)
            return
        }
        webView.evaluateJavaScript(Self.switchToVideoScript) { [weak self] result, error in
            if let error {
                DiagnosticsLogger.player.error("AV switch failed: \(error.localizedDescription, privacy: .public)")
            }
            let status = AVSwitchStatus(scriptResult: result)
            DiagnosticsLogger.player.info("AV switch: \(status?.rawValue ?? "unknown", privacy: .public)")
            if status?.pageNeedsSongRestore == true {
                self?.didSwitchPageToVideo = true
            }
            completion(status)
        }
    }

    /// Hands the page its Song preference back if Kaset switched it to Video.
    func restorePageSongModeIfNeeded() {
        guard self.didSwitchPageToVideo, let webView else { return }
        self.didSwitchPageToVideo = false
        webView.evaluateJavaScript(Self.restoreSongScript) { result, _ in
            let status = (result as? [String: Any])?["status"] as? String ?? "unknown"
            DiagnosticsLogger.player.info("AV restore song: \(status, privacy: .public)")
        }
    }
}
