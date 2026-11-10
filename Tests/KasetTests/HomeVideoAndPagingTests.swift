import AppKit
import Foundation
import Testing
@testable import Kaset

// MARK: - HomeVideoAndPagingTests

/// Home video tiles, swipe paging, the rounded radius scale and the shelf edge mask.
@Suite(.tags(.model))
@MainActor
struct HomeVideoAndPagingTests {
    private static func song(_ id: String, video: MusicVideoType?) -> HomeSectionItem {
        .song(Song(id: id, title: "Song \(id)", artists: [Artist(id: "a-\(id)", name: "Artist")], videoId: id, musicVideoType: video))
    }

    // MARK: Swipe tracker

    @Test("A horizontal trackpad swipe turns exactly one page, then swallows the rest and its momentum")
    func trackpadSwipePagesOnce() {
        var tracker = HomeSwipePagingTracker()
        #expect(tracker.handle(phase: .mayBegin, momentumPhase: [], deltaX: 0, deltaY: 0, timestamp: 0) == .pass)
        #expect(tracker.handle(phase: .began, momentumPhase: [], deltaX: -6, deltaY: 1, timestamp: 0.01) == .consume)
        #expect(tracker.handle(phase: .changed, momentumPhase: [], deltaX: -10, deltaY: 0, timestamp: 0.02) == .consume)
        // Fingers moved left (natural scrolling): reveal the page on the right.
        #expect(tracker.handle(phase: .changed, momentumPhase: [], deltaX: -12, deltaY: 0, timestamp: 0.03) == .page(towardsRight: true))
        #expect(tracker.handle(phase: .changed, momentumPhase: [], deltaX: -80, deltaY: 0, timestamp: 0.04) == .consume)
        #expect(tracker.handle(phase: .ended, momentumPhase: [], deltaX: 0, deltaY: 0, timestamp: 0.05) == .consume)
        #expect(tracker.handle(phase: [], momentumPhase: .began, deltaX: -40, deltaY: 0, timestamp: 0.06) == .consume)
        #expect(tracker.handle(phase: [], momentumPhase: .changed, deltaX: -40, deltaY: 0, timestamp: 0.07) == .consume)
        #expect(tracker.handle(phase: [], momentumPhase: .ended, deltaX: 0, deltaY: 0, timestamp: 0.08) == .consume)

        // The next gesture pages again, the other way.
        #expect(tracker.handle(phase: .began, momentumPhase: [], deltaX: 30, deltaY: 0, timestamp: 1) == .page(towardsRight: false))
    }

    @Test("A vertical gesture passes through to the page, momentum included")
    func verticalGesturePasses() {
        var tracker = HomeSwipePagingTracker()
        #expect(tracker.handle(phase: .began, momentumPhase: [], deltaX: 2, deltaY: -9, timestamp: 0) == .pass)
        #expect(tracker.handle(phase: .changed, momentumPhase: [], deltaX: -60, deltaY: -1, timestamp: 0.01) == .pass)
        #expect(tracker.handle(phase: .ended, momentumPhase: [], deltaX: 0, deltaY: 0, timestamp: 0.02) == .pass)
        #expect(tracker.handle(phase: [], momentumPhase: .changed, deltaX: 0, deltaY: -30, timestamp: 0.03) == .pass)
    }

    @Test("Shift-scroll ticks page once per burst")
    func wheelBurstsPageOnce() {
        var tracker = HomeSwipePagingTracker()
        #expect(tracker.handle(phase: [], momentumPhase: [], deltaX: -4, deltaY: 0, timestamp: 0) == .page(towardsRight: true))
        #expect(tracker.handle(phase: [], momentumPhase: [], deltaX: -4, deltaY: 0, timestamp: 0.1) == .consume)
        #expect(tracker.handle(phase: [], momentumPhase: [], deltaX: -4, deltaY: 0, timestamp: 0.3) == .consume)
        #expect(tracker.handle(phase: [], momentumPhase: [], deltaX: 4, deltaY: 0, timestamp: 1.2) == .page(towardsRight: false))
        // Plain vertical wheel scrolling is the page's.
        #expect(tracker.handle(phase: [], momentumPhase: [], deltaX: 0, deltaY: -3, timestamp: 2) == .pass)
    }

    // MARK: Radius scale

    @Test("Artwork radius follows the Tune scale by size")
    func artworkRadius() {
        #expect(TuneTheme.Radius.artwork(side: 32) == TuneTheme.Radius.small)
        #expect(TuneTheme.Radius.artwork(side: 40) == TuneTheme.Radius.small)
        #expect(TuneTheme.Radius.artwork(side: 160) == TuneTheme.Radius.artwork)
        #expect(TuneTheme.Radius.artwork(for: CGSize(width: 284, height: 160)) == TuneTheme.Radius.artwork)
        #expect(TuneTheme.Radius.artwork(for: CGSize(width: 520, height: 292)) == TuneTheme.Radius.hero)
        #expect(HomeItemCell.cornerRadius == TuneTheme.Radius.artwork)
    }

    // MARK: Videos

    @Test("Mostly-video lists get 16:9 row thumbnails; mostly-song lists keep squares")
    func videoRowThumbnails() {
        let longListens = (0 ..< 13).map { Self.song("\($0)", video: .ugc) }
        let heardInShorts = (0 ..< 19).map { Self.song("\($0)", video: .atv) } + [Self.song("omv", video: .omv)]
        #expect(HomeSongGridLayout.usesVideoThumbnails(longListens))
        #expect(!HomeSongGridLayout.usesVideoThumbnails(heardInShorts))
        #expect(!HomeSongGridLayout.usesVideoThumbnails([]))
        #expect(HomeSongGridLayout.videoThumbnailWidth == 71)
    }

    @Test("Video captions keep their counts; the VIDEO tag lives on the artwork")
    func videoCaption() {
        let video = HomeSectionItem.song(Song(
            id: "v",
            title: "LIMBO (Live Performance) | Vevo",
            artists: [Artist(id: "UCkeshi", name: "keshi")],
            videoId: "v",
            musicVideoType: .omv
        ))
        #expect(video.isVideoSong)
        #expect(HomeCardCaption.make(for: video) == HomeCardCaption(text: "keshi", meta: nil))
        #expect(HomeItemCell.width(for: video) == HomeItemCell.videoWidth)
        #expect(TuneVideoTag.text == String(localized: "Video").uppercased())
    }

    // MARK: Parser (live-feed shape)

    private static func twoRow(_ id: String, title: String, type: String, thumbnail: String, aspect: String) -> [String: Any] {
        [
            "musicTwoRowItemRenderer": [
                "title": ["runs": [["text": title]]],
                "subtitle": ["runs": [["text": "Artist \(id)"], ["text": " • "], ["text": "2.3M views"]]],
                "aspectRatio": aspect,
                "thumbnailRenderer": ["musicThumbnailRenderer": ["thumbnail": ["thumbnails": [["url": thumbnail, "width": 800, "height": 450]]]]],
                "navigationEndpoint": [
                    "watchEndpoint": [
                        "videoId": id,
                        "watchEndpointMusicSupportedConfigs": ["watchEndpointMusicConfig": ["musicVideoType": type]],
                    ],
                ],
            ],
        ]
    }

    @Test("Continuation pages keep video shelves and their 16:9 items in feed order")
    func continuationKeepsVideos() throws {
        // Shape of a signed-in FEmusic_home continuation (sanitized): a mixed
        // "Listen again"-style carousel and an all-video "Music videos for you".
        let mixed: [String: Any] = [
            "musicCarouselShelfRenderer": [
                "header": ["musicCarouselShelfBasicHeaderRenderer": ["title": ["runs": [["text": "Forgotten favorites"]]]]],
                "contents": [
                    Self.twoRow("atv1", title: "Photograph", type: "MUSIC_VIDEO_TYPE_ATV", thumbnail: "https://yt3.googleusercontent.com/x=w544-h544-l90-rj", aspect: "MUSIC_TWO_ROW_ITEM_THUMBNAIL_ASPECT_RATIO_SQUARE"),
                    Self.twoRow("ugc1", title: "Put Your Records On", type: "MUSIC_VIDEO_TYPE_UGC", thumbnail: "https://i.ytimg.com/vi/ugc1/hq720.jpg", aspect: "MUSIC_TWO_ROW_ITEM_THUMBNAIL_ASPECT_RATIO_RECTANGLE_16_9"),
                ],
            ],
        ]
        let videos: [String: Any] = [
            "musicCarouselShelfRenderer": [
                "header": ["musicCarouselShelfBasicHeaderRenderer": ["title": ["runs": [["text": "Music videos for you"]]]]],
                "contents": (0 ..< 3).map {
                    Self.twoRow("omv\($0)", title: "Video \($0)", type: "MUSIC_VIDEO_TYPE_OMV", thumbnail: "https://i.ytimg.com/vi/omv\($0)/hq720.jpg", aspect: "MUSIC_TWO_ROW_ITEM_THUMBNAIL_ASPECT_RATIO_RECTANGLE_16_9")
                },
            ],
        ]
        let data: [String: Any] = ["continuationContents": ["sectionListContinuation": ["contents": [mixed, videos]]]]

        let sections = HomeResponseParser.parseContinuation(data)
        #expect(sections.map { $0.title } == ["Forgotten favorites", "Music videos for you"])
        let first = try #require(sections.first)
        #expect(first.items.map { $0.isVideoSong } == [false, true])
        #expect(sections[1].items.count == 3)
        #expect(sections[1].items.allSatisfy { $0.isVideoSong })
        #expect(HomeShelfStyle.style(for: sections[1], at: 5) == .shelf)
    }

    // MARK: Shelf edge mask

    @Test("Shelves end at the gutters and fade only on a side with more cards")
    func edgeMask() {
        let atRest = HomeItemShelfContainerView.edgeMaskLocations(width: 1000, inset: 40, fadesLeft: false, fadesRight: true)
            .map { $0.doubleValue }
        #expect(atRest == [0, 0.04, 0.04, 0.924, 0.96, 1])
        let middle = HomeItemShelfContainerView.edgeMaskLocations(width: 1000, inset: 40, fadesLeft: true, fadesRight: true)
            .map { $0.doubleValue }
        #expect(middle == [0, 0.04, 0.076, 0.924, 0.96, 1])
        let paired = HomeItemShelfContainerView.edgeMaskLocations(width: 500, inset: 0, fadesLeft: false, fadesRight: false)
            .map { $0.doubleValue }
        #expect(paired == [0, 0, 0, 1, 1, 1])
        let empty = HomeItemShelfContainerView.edgeMaskLocations(width: 0, inset: 40, fadesLeft: true, fadesRight: true)
        #expect(empty.count == 6)
    }
}
