import JavaScriptCore
import Testing
@testable import Kaset

/// YouTube Music lowers loud tracks itself (`loudnessDb` > 0). Everything that writes the
/// element volume (transition engine, observer enforcement during fades, crossfade deck)
/// must scale by the same trim, or loud tracks come back hotter than YouTube plays them
/// after every crossfade and their peaks clip (measured: +2.3 dB, 26 893 clipped frames
/// in one minute of a `loudnessDb` 2.27 track).
@Suite("YouTube loudness trim", .tags(.service))
@MainActor
struct WebPlaybackLoudnessTests {
    private func trim(_ player: String) throws -> JSValue? {
        let context = try #require(JSContext())
        context.evaluateScript(WebPlaybackLoudness.trimFunction)
        return context.evaluateScript("__kasetLoudnessTrimFor(\(player))")
    }

    private static func player(db: String, responseId: String = "'aaaaaaaaaaa'", playingId: String = "'aaaaaaaaaaa'") -> String {
        """
        ({ getPlayerResponse: function() { return { videoDetails: { videoId: \(responseId) },
             playerConfig: { audioConfig: { loudnessDb: \(db) } } }; },
           getVideoData: function() { return { video_id: \(playingId) }; } })
        """
    }

    @Test("A loud track gets YouTube's own trim")
    func loudTrackIsTrimmed() throws {
        let value = try #require(try self.trim(Self.player(db: "2.27"))?.toDouble())
        #expect(abs(value - 0.770_016) < 0.000_01)
    }

    @Test("Tracks at or below the reference, or without loudness, are not trimmed")
    func quietOrUnknownIsUntouched() throws {
        #expect(try self.trim(Self.player(db: "-4.49"))?.toDouble() == 1)
        #expect(try self.trim(Self.player(db: "0"))?.toDouble() == 1)
        #expect(try self.trim(Self.player(db: "undefined"))?.toDouble() == 1)
        #expect(try self.trim("null")?.toDouble() == 1)
        #expect(try self.trim("({ getPlayerResponse: function() { throw new Error('x'); } })")?.toDouble() == 1)
    }

    @Test("A player response for another video is unknown, not trusted")
    func staleResponseIsUnknown() throws {
        #expect(try self.trim(Self.player(db: "2.27", playingId: "'bbbbbbbbbbb'"))?.isNull == true)
    }

    @Test("The crossfade deck scales its volume by the same trim")
    func deckUsesTrim() throws {
        let script = try #require(CrossfadeDeckScript.script(channelToken: 1, videoId: "aaaaaaaaaaa", volume: 0.5))
        #expect(script.contains("function __kasetLoudnessTrimFor("))
        #expect(script.contains("volume * loudnessTrim() * clampUnit(gain)"))
    }
}
