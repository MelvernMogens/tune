import Testing
@testable import Kaset

@Suite("YouTubeViewModelStore", .serialized, .tags(.viewModel))
@MainActor
struct YouTubeViewModelStoreTests {
    @Test("Guest refresh reloads the public video feeds that were loaded")
    func guestRefreshReloadsLoadedPublicVideoFeeds() async {
        let client = MockYouTubeClient()
        client.homeFeed = YouTubeFeed(
            videos: [MockYouTubeClient.makeVideo(videoId: "guest-home")],
            continuation: nil
        )
        client.destinationFeed = YouTubeFeed(
            videos: [MockYouTubeClient.makeVideo(videoId: "guest-explore")],
            continuation: nil
        )
        client.shorts = [MockYouTubeClient.makeVideo(videoId: "guest-short", isShort: true)]
        let sut = YouTubeViewModelStore(client: client)
        await sut.home.load()
        await sut.explore.load()
        await sut.shorts.load()

        await sut.refreshGuestContent()

        #expect(client.homeFeedCallCount == 2)
        #expect(client.destinationFeedCallCount == 2)
        #expect(client.lastDestination == .gaming)
        #expect(client.shortsCallCount == 2)
        #expect(sut.home.videos.map(\.videoId) == ["guest-home"])
        #expect(sut.explore.videos.map(\.videoId) == ["guest-explore"])
        #expect(sut.shorts.shorts.map(\.videoId) == ["guest-short"])
    }

    @Test("Guest refresh leaves never-opened video feeds unloaded")
    func guestRefreshSkipsUnopenedFeeds() async {
        let client = MockYouTubeClient()
        let sut = YouTubeViewModelStore(client: client)

        await sut.refreshGuestContent()

        #expect(client.homeFeedCallCount == 0)
        #expect(client.destinationFeedCallCount == 0)
        #expect(client.shortsCallCount == 0)
        #expect(sut.home.loadingState == .idle)
    }
}
