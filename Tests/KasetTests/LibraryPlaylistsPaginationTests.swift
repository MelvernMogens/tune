import Foundation
import Testing
@testable import Kaset

/// Parser tests for library playlist pagination (FEmusic_liked_playlists continuations).
@Suite(.tags(.parser))
struct LibraryPlaylistsPaginationTests {
    @Test("First library playlists page exposes its continuation token")
    func parseFirstPlaylistsPage() throws {
        let data = try LibraryPlaylistsFixtures.load("library_playlists_page")
        let page = PlaylistParser.parseLibraryPlaylistsPage(data)

        #expect(page.playlists.count == 20)
        #expect(page.playlists.first?.id == "VLPLFIXTURE001")
        #expect(page.playlists.last?.id == "VLPLFIXTURE020")
        #expect(page.nextPages == ["playlists-page-2"])
        #expect(page.isRecognized)
    }

    @Test("First library playlists page skips the create-playlist tile")
    func firstPageSkipsCreatePlaylistTile() throws {
        let data = try LibraryPlaylistsFixtures.load("library_playlists_page")
        let page = PlaylistParser.parseLibraryPlaylistsPage(data)

        #expect(!page.playlists.contains { $0.title == "New playlist" })
    }

    @Test("Legacy grid continuation parses playlists and the next token")
    func parseGridContinuation() throws {
        let data = try LibraryPlaylistsFixtures.load("library_playlists_continuation")
        let page = PlaylistParser.parseLibraryPlaylistsContinuation(data)

        #expect(page.playlists.map(\.id) == (21 ... 40).map { String(format: "VLPLFIXTURE%03d", $0) })
        #expect(page.nextPage == "playlists-page-3")
        #expect(page.isRecognized)
    }

    @Test("Append-action continuation parses the final page without a token")
    func parseAppendActionContinuation() throws {
        let data = try LibraryPlaylistsFixtures.load("library_playlists_continuation_last")
        let page = PlaylistParser.parseLibraryPlaylistsContinuation(data)

        #expect(page.playlists.count == 5)
        #expect(page.nextPage == nil)
        #expect(page.isRecognized)
    }

    @Test("Continuation-item-renderer token is followed for playlist shelves")
    func parseContinuationItemRendererToken() {
        let data: [String: Any] = [
            "continuationContents": [
                "musicShelfContinuation": [
                    "contents": [
                        [
                            "musicResponsiveListItemRenderer": [
                                "navigationEndpoint": [
                                    "browseEndpoint": ["browseId": "VLPLSHELF1"],
                                ],
                                "flexColumns": [[
                                    "musicResponsiveListItemFlexColumnRenderer": [
                                        "text": ["runs": [["text": "Shelf Playlist"]]],
                                    ],
                                ]],
                            ],
                        ],
                        [
                            "continuationItemRenderer": [
                                "continuationEndpoint": [
                                    "continuationCommand": ["token": "playlists-shelf-next"],
                                ],
                            ],
                        ],
                    ],
                ],
            ],
        ]

        let page = PlaylistParser.parseLibraryPlaylistsContinuation(data)

        #expect(page.playlists.map(\.id) == ["VLPLSHELF1"])
        #expect(page.nextPage == "playlists-shelf-next")
        #expect(page.isRecognized)
    }

    @Test("Unknown continuation shape is reported as unrecognized")
    func unknownContinuationIsUnrecognized() {
        let page = PlaylistParser.parseLibraryPlaylistsContinuation(["continuationContents": [:]])

        #expect(page.playlists.isEmpty)
        #expect(page.nextPage == nil)
        #expect(!page.isRecognized)
    }
}

// MARK: - LibraryPlaylistsFixtures

enum LibraryPlaylistsFixtures {
    static func load(_ name: String) throws -> [String: Any] {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json"))
        let data = try Data(contentsOf: url)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
