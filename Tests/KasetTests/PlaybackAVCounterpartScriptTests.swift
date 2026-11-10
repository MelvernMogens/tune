import JavaScriptCore
import Testing
@testable import Kaset

// MARK: - PlaybackAVCounterpartScriptTests

/// YouTube Music's Song/Video switch: a song's music-video counterpart must read as the same
/// queue entry, and Kaset must use the page's own toggle (never a forced `videoMode`).
@Suite(.tags(.service))
@MainActor
struct PlaybackAVCounterpartScriptTests {
    // MARK: Counterpart mapping

    @Test("A counterpart video id maps back to its song")
    func counterpartMapsToPrimary() throws {
        let context = try self.makeContext()
        #expect(self.string("__kasetCanonicalVideoId('mv1')", in: context) == "song1")
        #expect(self.string("__kasetCanonicalVideoId('song1')", in: context) == "song1")
        #expect(self.string("__kasetCanonicalVideoId('other')", in: context) == "other")
        #expect(self.string("__kasetCanonicalVideoId('')", in: context) == "")
        #expect(self.string("window.__kasetCanonicalVideoId('mv1')", in: context) == "song1")
    }

    @Test("A queue entry that is itself the video is never remapped")
    func primaryEntryWins() throws {
        let context = try self.makeContext(extraWrappers: "wrappers.push(wrapper('mv1', null));")
        #expect(self.string("__kasetCanonicalVideoId('mv1')", in: context) == "mv1")
    }

    @Test("The playing entry's own pairing beats a separate entry for its music video")
    func selectedEntryPairingWins() throws {
        let context = try self.makeContext(extraWrappers: """
        wrappers.push(wrapper('mv1', null));
        wrappers[1].querySelector = function(selector) {
            return selector === 'ytmusic-player-queue-item[selected]' ? {} : null;
        };
        """)
        #expect(self.string("__kasetCanonicalVideoId('mv1')", in: context) == "song1")
        // Other entries keep the primary-wins rule.
        #expect(self.string("__kasetCanonicalVideoId('mv0')", in: context) == "song0")
    }

    @Test("Malformed queue data leaves ids untouched")
    func malformedQueueData() throws {
        let context = try self.makeContext(extraWrappers: """
        wrappers.unshift({ data: null }, { data: { primaryRenderer: {} } }, { data: { counterpart: 'x' } });
        """)
        #expect(self.string("__kasetCanonicalVideoId('mv1')", in: context) == "song1")
        #expect(self.string("__kasetCanonicalVideoId('nope')", in: context) == "nope")
    }

    // MARK: Availability

    @Test("Video availability needs a counterpart or a picture, not just the toggle")
    func availability() throws {
        let context = try self.makeContext()
        #expect(self.bool("__kasetCurrentItemHasVideo()", in: context))

        // The toggle renders (disabled) for every song: no counterpart, audio-only media.
        context.evaluateScript("delete toggle.attributes['selected-queue-item-has-counterpart'];")
        #expect(!self.bool("__kasetCurrentItemHasVideo()", in: context))

        // The item itself is a video (official music video, upload).
        context.evaluateScript("video.videoWidth = 640; video.videoHeight = 360;")
        #expect(self.bool("__kasetCurrentItemHasVideo()", in: context))
    }

    // MARK: Switching

    @Test("Switching to video clicks the page's Video button for a song with a counterpart")
    func switchClicksVideoButton() throws {
        let context = try self.makeContext()
        let result = context.evaluateScript(SingletonPlayerWebView.switchToVideoScript)
        #expect(SingletonPlayerWebView.AVSwitchStatus(scriptResult: result?.toObject()) == .switched)
        #expect(context.evaluateScript("videoButton.clicks")?.toInt32() == 1)
        #expect(context.evaluateScript("songButton.clicks")?.toInt32() == 0)
    }

    @Test("Switching to video leaves a page already on Video alone")
    func switchIsIdempotent() throws {
        let context = try self.makeContext()
        context.evaluateScript("toggle.attributes['playback-mode'] = 'OMV_PREFERRED';")
        let result = context.evaluateScript(SingletonPlayerWebView.switchToVideoScript)
        #expect(SingletonPlayerWebView.AVSwitchStatus(scriptResult: result?.toObject()) == .alreadyVideo)
        #expect(context.evaluateScript("videoButton.clicks")?.toInt32() == 0)
    }

    @Test("Switching to video reports an audio-only song without a counterpart")
    func switchWithoutCounterpart() throws {
        let context = try self.makeContext()
        context.evaluateScript("delete toggle.attributes['selected-queue-item-has-counterpart'];")
        var result = context.evaluateScript(SingletonPlayerWebView.switchToVideoScript)
        #expect(SingletonPlayerWebView.AVSwitchStatus(scriptResult: result?.toObject()) == .noCounterpart)
        #expect(context.evaluateScript("videoButton.clicks")?.toInt32() == 0)

        context.evaluateScript("video.videoWidth = 1280; video.videoHeight = 720;")
        result = context.evaluateScript(SingletonPlayerWebView.switchToVideoScript)
        #expect(SingletonPlayerWebView.AVSwitchStatus(scriptResult: result?.toObject()) == .mediaHasVideo)
    }

    @Test("Restoring Song clicks the Song button only while the page is on Video")
    func restoreSong() throws {
        let context = try self.makeContext()
        var result = context.evaluateScript(SingletonPlayerWebView.restoreSongScript)
        #expect(result?.objectForKeyedSubscript("status")?.toString() == "alreadySong")
        #expect(context.evaluateScript("songButton.clicks")?.toInt32() == 0)

        context.evaluateScript("toggle.attributes['playback-mode'] = 'OMV_PREFERRED';")
        result = context.evaluateScript(SingletonPlayerWebView.restoreSongScript)
        #expect(result?.objectForKeyedSubscript("status")?.toString() == "restored")
        #expect(context.evaluateScript("songButton.clicks")?.toInt32() == 1)
    }

    @Test("Only a switch Kaset made asks for the Song preference back")
    func switchStatusParsing() {
        typealias Status = SingletonPlayerWebView.AVSwitchStatus
        #expect(Status(scriptResult: ["status": "switched"]) == .switched)
        #expect(Status(scriptResult: ["status": "noCounterpart"]) == .noCounterpart)
        #expect(Status(scriptResult: ["status": "bogus"]) == nil)
        #expect(Status(scriptResult: nil) == nil)
        #expect(Status(scriptResult: "switched") == nil)
        #expect(Status.switched.pageNeedsSongRestore)
        #expect(!Status.alreadyVideo.pageNeedsSongRestore)
        #expect(!Status.mediaHasVideo.pageNeedsSongRestore)
        #expect(!Status.noCounterpart.pageNeedsSongRestore)
    }

    // MARK: Observer

    @Test("The observer reports the song while its music video plays, without the video's metadata")
    func observerAliasesCounterpart() throws {
        let context = try MusicPlaybackObserverTestContext.make(setup: """
        var queueWrappers = [{
            data: {
                primaryRenderer: { playlistPanelVideoRenderer: { videoId: 'v1' } },
                counterpart: [{ counterpartRenderer: { playlistPanelVideoRenderer: { videoId: 'mv1' } } }]
            }
        }];
        document.querySelectorAll = function(selector) {
            return selector === 'ytmusic-playlist-panel-video-wrapper-renderer' ? queueWrappers : [];
        };
        """)
        // YouTube Music swaps the same <video> to the counterpart at the mapped position.
        context.evaluateScript("""
        currentDataVideoId = 'mv1';
        titleElement.textContent = 'v1 (Official Video)';
        window.location = { href: 'https://music.youtube.com/watch?v=mv1' };
        video.currentSrc = 'https://media.example/mv1';
        video.currentTime = 30;
        video.duration = 240;
        video.videoWidth = 640;
        video.videoHeight = 360;
        dispatch('loadedmetadata');
        fakeNow = 5000;
        dispatch('timeupdate');
        """)
        let snapshot = context.evaluateScript(SingletonPlayerWebView.playbackSnapshotScript)
        #expect(snapshot?.objectForKeyedSubscript("videoId")?.toString() == "v1")

        let updates = try #require(
            context.evaluateScript("messages.filter(function(m) { return m.type === 'STATE_UPDATE'; })")?
                .toArray() as? [[String: Any]]
        )
        let last = try #require(updates.last)
        #expect(last["videoId"] as? String == "v1")
        #expect(last["mediaVideoId"] as? String == "v1")
        #expect(last["title"] as? String == "")
        #expect(last["thumbnailUrl"] as? String == "")
        #expect(last["trackChanged"] as? Bool == false)
        #expect(last["hasVideo"] as? Bool == true)
        #expect(context.exception == nil)
    }

    // MARK: Helpers

    private func makeContext(extraWrappers: String = "") throws -> JSContext {
        let context = try #require(JSContext())
        context.exceptionHandler = { _, exception in
            Issue.record("JavaScript exception: \(exception?.toString() ?? "unknown")")
        }
        context.evaluateScript("""
        var window = globalThis;
        function button() {
            return { clicks: 0, attributes: {}, click: function() { this.clicks += 1; },
                     getAttribute: function(name) { return this.attributes[name] || null; } };
        }
        var videoButton = button();
        var songButton = button();
        var toggle = {
            attributes: {
                'playback-mode': 'ATV_PREFERRED',
                'toggle-disabled': '',
                'selected-queue-item-has-counterpart': ''
            },
            getAttribute: function(name) {
                return Object.prototype.hasOwnProperty.call(this.attributes, name) ? this.attributes[name] : null;
            },
            hasAttribute: function(name) { return Object.prototype.hasOwnProperty.call(this.attributes, name); },
            querySelector: function(selector) {
                if (selector === '.video-button') return videoButton;
                if (selector === '.song-button') return songButton;
                return null;
            }
        };
        var video = { videoWidth: 0, videoHeight: 0 };
        function wrapper(primaryId, counterpartId) {
            var data = { primaryRenderer: { playlistPanelVideoRenderer: { videoId: primaryId } } };
            if (counterpartId) {
                data.counterpart = [{ counterpartRenderer: { playlistPanelVideoRenderer: { videoId: counterpartId } } }];
            }
            return { data: data };
        }
        var wrappers = [wrapper('song0', 'mv0'), wrapper('song1', 'mv1')];
        \(extraWrappers)
        var document = {
            querySelector: function(selector) {
                if (selector === 'ytmusic-av-toggle') return toggle;
                if (selector === 'video') return video;
                return null;
            },
            querySelectorAll: function(selector) {
                return selector === 'ytmusic-playlist-panel-video-wrapper-renderer' ? wrappers : [];
            }
        };
        """)
        context.evaluateScript(SingletonPlayerWebView.avCounterpartFunctionJS)
        return context
    }

    private func string(_ script: String, in context: JSContext) -> String? {
        context.evaluateScript(script)?.toString()
    }

    private func bool(_ script: String, in context: JSContext) -> Bool {
        context.evaluateScript(script)?.toBool() ?? false
    }
}
