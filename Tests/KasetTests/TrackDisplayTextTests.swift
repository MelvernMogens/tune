import Foundation
import Testing
@testable import Kaset

// MARK: - TrackDisplayTextTests

@Suite(.tags(.model))
struct TrackDisplayTextTests {
    // MARK: Bylines

    @Test("Separators around empty fields are dropped", arguments: [
        ("• Emerald •", "Emerald"),
        ("Emerald • ", "Emerald"),
        (" · Emerald · · 2024", "Emerald · 2024"),
        ("Hindia • Menari Dengan Bayangan", "Hindia · Menari Dengan Bayangan"),
        ("Hindia | Album", "Hindia · Album"),
        ("", ""),
        ("•", ""),
    ])
    func cleansBylines(raw: String, expected: String) {
        #expect(TrackDisplayText.cleanByline(raw) == expected)
    }

    // MARK: Titles

    @Test("Upload noise is removed from titles", arguments: [
        ("Bertaut [Official Lyric Video]", "Bertaut"),
        ("Bertaut (Official Music Video)", "Bertaut"),
        ("Bertaut (Official Audio)", "Bertaut"),
        ("Bertaut (Official Video)", "Bertaut"),
        ("Bertaut (Lyrics)", "Bertaut"),
        ("Bertaut (Lyric Video)", "Bertaut"),
        ("Bertaut (Official Video Lirik)", "Bertaut"),
        ("Bertaut (Video Lirik)", "Bertaut"),
        ("Bertaut (Official MV)", "Bertaut"),
        ("Bertaut 【MV】", "Bertaut"),
        ("Bertaut (M/V)", "Bertaut"),
        ("Bertaut (Visualizer)", "Bertaut"),
        ("Bertaut (Official Music Video) [HD]", "Bertaut"),
        ("Bertaut - Official Video", "Bertaut"),
        ("Bertaut | Official Music Video", "Bertaut"),
        ("• Bertaut •", "Bertaut"),
        ("Pamungkas - Closure ( Unofficial lirik dan terjemahan )", "Pamungkas - Closure (Unofficial lirik dan terjemahan)"),
        ("life with u - acoustic (acoustic) (feat. Gabriela Bee)", "life with u - acoustic (feat. Gabriela Bee)"),
    ])
    func removesNoise(raw: String, expected: String) {
        #expect(TrackDisplayText.cleanTitle(raw) == expected)
    }

    @Test("Meaningful qualifiers stay", arguments: [
        "Bad Habits (feat. Bring Me The Horizon)",
        "Yellow (Live at Glastonbury)",
        "Here Comes the Sun (Remastered 2009)",
        "Creep (Acoustic)",
        "Stay (Official)",
        "Love Story (Taylor's Version)",
    ])
    func keepsQualifiers(raw: String) {
        #expect(TrackDisplayText.cleanTitle(raw) == raw)
    }

    @Test("A title made only of noise falls back to the original")
    func keepsAllNoiseTitle() {
        #expect(TrackDisplayText.cleanTitle("(Official Video)") == "(Official Video)")
    }

    // MARK: Display

    @Test("'Artist - Title' fills an empty artist slot")
    func splitsArtistFromTitle() {
        let display = TrackDisplayText.display(title: "Pamungkas - To the Bone [Official Lyric Video]", artist: "")
        #expect(display == .init(title: "To the Bone", artist: "Pamungkas"))
    }

    @Test("A placeholder artist counts as empty")
    func placeholderArtistIsEmpty() {
        let display = TrackDisplayText.display(title: "Hindia - Evaluasi (Official Audio)", artist: "Unknown Artist")
        #expect(display == .init(title: "Evaluasi", artist: "Hindia"))
    }

    @Test("A title repeating the known artist drops the prefix")
    func dropsRepeatedArtistPrefix() {
        let display = TrackDisplayText.display(title: "Pamungkas - To the Bone (Official Video)", artist: "Pamungkas")
        #expect(display == .init(title: "To the Bone", artist: "Pamungkas"))
    }

    @Test("A dash title with a different known artist stays whole")
    func keepsDashTitleWithOtherArtist() {
        let display = TrackDisplayText.display(title: "Ruang Sendiri - Live Session", artist: "Tulus")
        #expect(display == .init(title: "Ruang Sendiri - Live Session", artist: "Tulus"))
    }

    @Test("A version suffix is not mistaken for an artist")
    func keepsVersionSuffix() {
        let display = TrackDisplayText.display(title: "Here Comes the Sun - Remastered 2009", artist: nil)
        #expect(display == .init(title: "Here Comes the Sun - Remastered 2009", artist: ""))
    }

    @Test("Part and mix suffixes are not mistaken for an artist", arguments: [
        "Song - Original Mix",
        "Intro - Part 2",
        "Theme - Extended Version",
        "Lagu - Slowed + Reverb",
    ])
    func keepsPartSuffixes(title: String) {
        #expect(TrackDisplayText.display(title: title, artist: "") == .init(title: title, artist: ""))
    }

    @Test("Ambiguous multi-dash titles stay whole")
    func keepsMultiDashTitle() {
        let display = TrackDisplayText.display(title: "A - B - C", artist: "")
        #expect(display == .init(title: "A - B - C", artist: ""))
    }

    @Test("Messy bylines are cleaned in the display artist")
    func cleansDisplayArtist() {
        let display = TrackDisplayText.display(title: "Kota", artist: "• Emerald •")
        #expect(display == .init(title: "Kota", artist: "Emerald"))
    }

    @Test("Song.displayText never changes the stored song")
    func songDisplayLeavesModelAlone() {
        let song = Song(
            id: "v1",
            title: "Hindia - Evaluasi (Official Audio)",
            artists: [],
            album: nil,
            duration: nil,
            videoId: "v1"
        )
        #expect(song.displayText == .init(title: "Evaluasi", artist: "Hindia"))
        #expect(song.title == "Hindia - Evaluasi (Official Audio)")
        #expect(song.videoId == "v1")
    }
}
