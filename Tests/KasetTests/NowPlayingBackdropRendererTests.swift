import AppKit
import Testing
@testable import Kaset

@Suite(.tags(.model))
struct NowPlayingBackdropRendererTests {
    @Test("The baked backdrop is a small bitmap, not a window-sized one")
    func bakedBackdropIsSmall() throws {
        let source = try #require(Self.solidImage(width: 96, height: 96, white: 0.5))
        let output = try #require(TuneNowPlayingBackdropRenderer.render(source, viewSize: CGSize(width: 1512, height: 982)))
        let cgImage = try #require(output.cgImage(forProposedRect: nil, context: nil, hints: nil))

        #expect(cgImage.width == TuneNowPlayingBackdropRenderer.outputEdge)
        #expect(cgImage.height == TuneNowPlayingBackdropRenderer.outputEdge)
        // 256 KB, against ≈24 MB for the old full-window drawingGroup at 2×.
        #expect(ImageCache.decodedByteCost(of: output) <= 256 * 256 * 4)
    }

    @Test("Wide artwork keeps its aspect in the baked bitmap")
    func wideArtworkKeepsAspect() throws {
        let source = try #require(Self.solidImage(width: 160, height: 90, white: 0.5))
        let output = try #require(TuneNowPlayingBackdropRenderer.render(source, viewSize: CGSize(width: 1000, height: 800)))
        let cgImage = try #require(output.cgImage(forProposedRect: nil, context: nil, hints: nil))

        #expect(cgImage.width == 256)
        #expect(cgImage.height == 144)
    }

    @Test("Darkening matches the old colorMultiply on a neutral field")
    func darkeningMatchesColorMultiply() throws {
        let source = try #require(Self.solidImage(width: 64, height: 64, white: 0.5))
        let output = try #require(TuneNowPlayingBackdropRenderer.render(source, viewSize: CGSize(width: 800, height: 600)))
        let pixel = try #require(Self.centerPixel(of: output))
        let expected = 0.5 * TuneTheme.NowPlaying.backdropBrightness * 255
        for channel in pixel {
            #expect(abs(Double(channel) - expected) <= 3)
        }
    }

    @Test("Blur radius scales from window points to bitmap pixels")
    func blurRadiusScales() {
        let look = TuneNowPlayingBackdropRenderer.Look(blurRadius: 90)
        // Square art filled over 1512×982 pt spans 1512 pt; 256 px across it.
        let radius = TuneNowPlayingBackdropRenderer.pixelBlurRadius(
            look: look,
            sourceAspect: 1,
            viewSize: CGSize(width: 1512, height: 982)
        )
        #expect(abs(radius - 90 * 256 / 1512) < 0.001)
        // Portrait window: the filled square spans the height.
        let tall = TuneNowPlayingBackdropRenderer.pixelBlurRadius(
            look: look,
            sourceAspect: 1,
            viewSize: CGSize(width: 600, height: 1200)
        )
        #expect(abs(tall - 90 * 256 / 1200) < 0.001)
        #expect(TuneNowPlayingBackdropRenderer.pixelBlurRadius(look: look, sourceAspect: 1, viewSize: .zero) == 0)
    }

    @Test("Live resizes snap to 128 pt buckets")
    func sizeBuckets() {
        #expect(TuneNowPlayingBackdropRenderer.sizeBucket(for: CGSize(width: 1512, height: 982)) == CGSize(width: 1536, height: 1024))
        #expect(TuneNowPlayingBackdropRenderer.sizeBucket(for: CGSize(width: 1500, height: 990)) == CGSize(width: 1536, height: 1024))
        #expect(TuneNowPlayingBackdropRenderer.sizeBucket(for: CGSize(width: 10, height: 10)) == CGSize(width: 128, height: 128))
    }

    private static func solidImage(width: Int, height: Int, white: CGFloat) -> NSImage? {
        guard let rep = NSBitmapImageRep(
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
        ), let context = NSGraphicsContext(bitmapImageRep: rep)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor(srgbRed: white, green: white, blue: white, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: NSSize(width: width, height: height))
        image.addRepresentation(rep)
        return image
    }

    private static func centerPixel(of image: NSImage) -> [UInt8]? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }
        var data = [UInt8](repeating: 0, count: 4)
        let drawn: Bool = data.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            let x = CGFloat(cgImage.width / 2)
            let y = CGFloat(cgImage.height / 2)
            context.draw(cgImage, in: CGRect(x: -x, y: -y, width: CGFloat(cgImage.width), height: CGFloat(cgImage.height)))
            return true
        }
        return drawn ? Array(data.prefix(3)) : nil
    }
}
