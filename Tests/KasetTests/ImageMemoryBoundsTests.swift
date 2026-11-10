import AppKit
import Foundation
import Testing
@testable import Kaset

// MARK: - ImageCacheMemoryBoundsTests

@Suite(.serialized, .tags(.service))
struct ImageCacheMemoryBoundsTests {
    @Test("Decodes downsample to 2× the point size, never the full source")
    func decodeIsBoundedByTargetSize() async throws {
        let directory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = Self.makeCache(directory: directory)
        let url = try #require(URL(string: "https://example.com/large.png"))
        await cache.saveToDiskForTesting(url: url, data: try Self.makePNGData(edge: 600))

        let image = try #require(await cache.image(for: url, targetSize: CGSize(width: 40, height: 40)))
        let cgImage = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))

        #expect(cgImage.width == 80)
        #expect(cgImage.height == 80)
        #expect(ImageCache.decodedByteCost(of: image) == cgImage.bytesPerRow * cgImage.height)
        #expect(ImageCache.decodedByteCost(of: image) < 600 * 600 * 4 / 10)
    }

    @Test("A wide source filled into a square target still covers it at 2×")
    func wideSourceCoversSquareTarget() async throws {
        let directory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = Self.makeCache(directory: directory)
        let url = try #require(URL(string: "https://example.com/wide.png"))
        await cache.saveToDiskForTesting(url: url, data: try Self.makePNGData(width: 1280, height: 720))

        let image = try #require(await cache.image(for: url, targetSize: CGSize(width: 160, height: 160)))
        let cgImage = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))

        // Aspect-filled into 160×160 pt, the short edge must reach 320 px (was 180 px: soft).
        #expect(cgImage.height == 320)
        #expect(cgImage.width >= 568 && cgImage.width <= 570)
    }

    @Test("Decode edge: square and matching aspects unchanged, mismatches cover, never above the source")
    func thumbnailMaxPixelSize() {
        let square = CGSize(width: 160, height: 160)
        #expect(ImageCache.thumbnailMaxPixelSize(sourcePixelSize: CGSize(width: 544, height: 544), targetSize: square) == 320)
        #expect(ImageCache.thumbnailMaxPixelSize(sourcePixelSize: nil, targetSize: square) == 320)
        // Matching 16:9 target: same as the old long-edge rule.
        #expect(ImageCache.thumbnailMaxPixelSize(
            sourcePixelSize: CGSize(width: 1280, height: 720),
            targetSize: CGSize(width: 320, height: 180)
        ) == 640)
        // 16:9 into a square: long edge grows so the short edge covers 320 px.
        #expect(ImageCache.thumbnailMaxPixelSize(sourcePixelSize: CGSize(width: 1280, height: 720), targetSize: square) == 569)
        // Small source: capped at what the source has (ImageIO never upscales).
        #expect(ImageCache.thumbnailMaxPixelSize(sourcePixelSize: CGSize(width: 480, height: 360), targetSize: CGSize(width: 400, height: 400)) == 800)
        #expect(ImageCache.thumbnailMaxPixelSize(sourcePixelSize: CGSize(width: 1280, height: 360), targetSize: square) == 1138)
        #expect(ImageCache.thumbnailMaxPixelSize(sourcePixelSize: CGSize(width: 0, height: 0), targetSize: square) == 320)
    }

    @Test("Disk hits are charged their decoded size, so the byte limit evicts")
    func diskHitsAreChargedAndEvicted() async throws {
        let directory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // One 100×100 pt decode is 200×200 px ≈ 160 KB; allow about two of them.
        let cache = Self.makeCache(directory: directory, memoryCostLimit: 2 * 200 * 200 * 4 + 1024)
        let targetSize = CGSize(width: 100, height: 100)
        let urls = try (0 ..< 6).map { index in
            try #require(URL(string: "https://example.com/art-\(index).png"))
        }
        let data = try Self.makePNGData(edge: 400)
        for url in urls {
            await cache.saveToDiskForTesting(url: url, data: data)
        }

        for url in urls {
            #expect(await cache.image(for: url, targetSize: targetSize) != nil)
        }

        let resident = urls.count(where: { cache.cachedImage(for: $0, targetSize: targetSize) != nil })
        // Before cost accounting, every disk hit stayed resident (cost 0).
        #expect(resident <= 3)
        #expect(cache.cachedImage(for: urls[urls.count - 1], targetSize: targetSize) != nil)
    }

    @Test("Trimming empties the memory tier but keeps the disk tier")
    func trimKeepsDiskTier() async throws {
        let directory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = Self.makeCache(directory: directory)
        let url = try #require(URL(string: "https://example.com/trim.png"))
        let targetSize = CGSize(width: 50, height: 50)
        await cache.saveToDiskForTesting(url: url, data: try Self.makePNGData(edge: 200))

        #expect(await cache.image(for: url, targetSize: targetSize) != nil)
        #expect(cache.cachedImage(for: url, targetSize: targetSize) != nil)

        cache.trimMemoryCache()

        #expect(cache.cachedImage(for: url, targetSize: targetSize) == nil)
        #expect(await cache.image(for: url, targetSize: targetSize) != nil)
    }

    private static func makeCache(directory: URL, memoryCostLimit: Int = ImageCache.defaultMemoryCostLimit) -> ImageCache {
        ImageCache(
            diskCacheURL: directory,
            startsEvictionTask: false,
            monitorsMemoryPressure: false,
            memoryCostLimit: memoryCostLimit
        )
    }

    private static func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImageCacheMemoryBoundsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func makePNGData(edge: Int) throws -> Data {
        try Self.makePNGData(width: edge, height: edge)
    }

    private static func makePNGData(width: Int, height: Int) throws -> Data {
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.systemTeal.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }
}

// MARK: - HomePrefetchRequestTests

@Suite(.tags(.model))
@MainActor
struct HomePrefetchRequestTests {
    @Test("Prefetch warms the exact URL and size the shelf cell requests first")
    func prefetchMatchesCellRequest() throws {
        let cover = try #require(URL(string: "https://lh3.googleusercontent.com/cover=w120-h120"))
        let frame = try #require(URL(string: "https://i.ytimg.com/vi/v2/hqdefault.jpg"))
        let album = HomeSectionItem.album(Album(id: "al", title: "Album", artists: nil, thumbnailURL: cover, year: nil, trackCount: nil))
        let video = HomeSectionItem.song(Song(
            id: "v2",
            title: "Video",
            artists: [Artist(id: "a", name: "Artist")],
            thumbnailURL: frame,
            videoId: "v2",
            musicVideoType: .omv
        ))

        let requests = HomeItemCell.prefetchRequests(for: [album, video, album])

        #expect(requests.count == 2)
        let square = try #require(requests.first { $0.0 == HomeItemCell.artworkTargetSize(for: album) })
        #expect(square.1 == [HomeItemCell.thumbnailURLs(for: album)[0], HomeItemCell.thumbnailURLs(for: album)[0]])
        let wide = try #require(requests.first { $0.0 == HomeItemCell.artworkTargetSize(for: video) })
        #expect(wide.1 == [HomeItemCell.thumbnailURLs(for: video)[0]])
        #expect(wide.0.width == HomeItemCell.videoWidth)
    }
}
