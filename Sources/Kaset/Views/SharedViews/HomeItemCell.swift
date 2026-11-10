import AppKit
import SwiftUI

// MARK: - HomeItemCell

/// Native card as a single layer-backed view with no backing store of its
/// own. Everything static — title, subtitle, explicit badge, chart rank, like
/// button — is a cached bitmap on a sublayer; the artwork and its hover lift
/// are sublayers too; the glass play overlay is the one piece of SwiftUI,
/// hosted only while the card is hovered.
///
/// One `NSView` per card is the point: SwiftUI detaches and re-attaches each
/// shelf's platform view as it crosses the viewport, and AppKit's cost for
/// that (and for every scroll frame while attached) scales with the number of
/// views in the subtree. Measured with a multi-view card it was ~7 dropped
/// frames per scroll pass; with a 3-view card, under 1.
@MainActor
final class HomeItemCell: NSView {
    static let artworkHeight: CGFloat = 160
    static let squareWidth: CGFloat = 160
    static let videoWidth: CGFloat = 284
    /// Artwork + 8pt gap + two title lines + caption.
    static let height: CGFloat = 220
    /// Shelf artwork corners (continuous), on the Tune radius scale.
    static let cornerRadius: CGFloat = TuneTheme.Radius.artwork
    /// Hover play affordance: a small rounded square in the artwork's corner.
    static let playOverlaySize: CGFloat = 28
    static let playOverlayInset: CGFloat = 8
    static let likeButtonSize: CGFloat = 22
    static let likeButtonInset: CGFloat = 6

    static func width(for item: HomeSectionItem) -> CGFloat {
        item.isVideoSong ? self.videoWidth : self.squareWidth
    }

    var menuProvider: (() -> NSMenu?)?
    /// Called when the like control (drawn at the artwork's top-trailing corner) is clicked.
    var likeAction: (() -> Void)?

    private let artwork = HomeItemArtworkLayers()
    /// Like control, chart rank and the VIDEO tag sit above the artwork.
    private let likeLayer = CALayer()
    private let rankLayer = CALayer()
    private let videoTagLayer = CALayer()
    /// Title, subtitle and explicit badge, rendered once into a cached bitmap.
    /// A layer (rather than `draw(_:)`) because AppKit redisplays a view's
    /// backing store every time SwiftUI re-attaches the shelf at the viewport
    /// edge, and re-typesetting every card's text there dropped frames.
    private let textLayer = CALayer()
    private var textLayerKey: String?
    private var playOverlay: NSHostingView<AnyView>?

    private(set) var item: HomeSectionItem?
    /// `item.homeCardSubtitle`, parsed once per configure rather than on
    /// every re-attach. Used for accessibility.
    private var subtitle = ""
    /// The drawn caption: text left, monospaced tag right (C2 `.cm`).
    private var caption = HomeCardCaption(text: "", meta: nil)
    private var rank: Int?
    private var playlistPlayAction: (() -> Void)?
    private var environment = EnvironmentValues()
    private var allowsLikeActions = false
    private var isLiked = false
    private var isLikeFocused = false
    private var overlayScale: CGFloat = 0
    private(set) var isHovered = false
    private var imageLoadTask: Task<Void, Never>?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.wantsLayer = true
        self.layerContentsRedrawPolicy = .onSetNeedsDisplay
        self.textLayer.contentsGravity = .resize
        self.layer?.addSublayer(self.textLayer)
        self.layer?.addSublayer(self.artwork.liftLayer)
        self.likeLayer.contentsGravity = .center
        self.likeLayer.isHidden = true
        // The view is flipped, so "top" gravity lands at the visual bottom.
        self.rankLayer.contentsGravity = .topLeft
        self.rankLayer.isHidden = true
        self.layer?.addSublayer(self.rankLayer)
        self.videoTagLayer.contentsGravity = .center
        self.videoTagLayer.isHidden = true
        self.layer?.addSublayer(self.videoTagLayer)
        self.layer?.addSublayer(self.likeLayer)
        self.focusRingType = .exterior
        self.setAccessibilityElement(true)
        self.setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }

    override var isFlipped: Bool {
        true
    }

    /// Frame of the like control in the view's coordinates, or nil when it is not shown.
    var likeButtonFrame: NSRect? {
        guard self.showsLikeButton, let item else { return nil }
        return self.likeControlFrame(width: Self.width(for: item))
    }

    private var isRightToLeft: Bool {
        self.environment.layoutDirection == .rightToLeft
    }

    private func likeControlFrame(width: CGFloat) -> NSRect {
        NSRect(
            x: self.isRightToLeft ? Self.likeButtonInset : width - Self.likeButtonInset - Self.likeButtonSize,
            y: Self.likeButtonInset,
            width: Self.likeButtonSize,
            height: Self.likeButtonSize
        )
    }

    private var supportsLikeAction: Bool {
        guard let item, case .song = item else { return false }
        return self.allowsLikeActions
    }

    private var showsLikeButton: Bool {
        self.supportsLikeAction && (self.isLiked || self.isHovered || self.isLikeFocused)
    }

    override func layout() {
        super.layout()
        guard let item else { return }
        let scale = self.window?.backingScaleFactor ?? 2
        let width = Self.width(for: item)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.artwork.layout(in: NSRect(x: 0, y: 0, width: width, height: Self.artworkHeight), scale: scale)
        self.textLayer.frame = NSRect(x: 0, y: Self.artworkHeight, width: width, height: Self.height - Self.artworkHeight)
        // Flipped view: layer frames are in the view's (top-left origin) space.
        self.likeLayer.frame = self.likeControlFrame(width: width)
        // C2: the rank sits in a solid block on the artwork's bottom-leading corner.
        self.rankLayer.frame = NSRect(x: 0, y: 0, width: width, height: Self.artworkHeight)
        self.rankLayer.contentsGravity = self.isRightToLeft ? .topRight : .topLeft
        self.videoTagLayer.frame = self.videoTagFrame(width: width)
        if self.overlayScale != scale {
            self.updateOverlayLayers()
        }
        CATransaction.commit()
    }

    /// Off-window cards (shelves SwiftUI has detached) drop their text bitmap;
    /// re-attaching restores it from the shared cache in `updateLayer`.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if self.window == nil {
            self.setTextImage(nil, key: nil)
        } else {
            self.needsDisplay = true
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        self.needsLayout = true
        self.needsDisplay = true
    }

    private func updateOverlayLayers() {
        let scale = self.window?.backingScaleFactor ?? 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.effectiveAppearance.performAsCurrentDrawingAppearance {
            if self.showsLikeButton {
                self.likeLayer.contents = self.likeImage(liked: self.isLiked, scale: scale)
                self.likeLayer.isHidden = false
            } else {
                self.likeLayer.isHidden = true
            }
            if let rank {
                self.rankLayer.contents = Self.rankImage(rank, scale: scale)
                self.rankLayer.isHidden = false
            } else {
                self.rankLayer.isHidden = true
            }
            if let item = self.item, item.isVideoSong {
                self.videoTagLayer.contents = Self.videoTagImage(scale: scale)
                self.videoTagLayer.isHidden = false
            } else {
                self.videoTagLayer.isHidden = true
            }
        }
        self.likeLayer.contentsScale = scale
        self.rankLayer.contentsScale = scale
        self.videoTagLayer.contentsScale = scale
        self.overlayScale = scale
        CATransaction.commit()
    }

    /// The unliked glyph resolves a dynamic color; bitmap resolution must also
    /// match the destination layer's backing scale.
    private static var likeImages: [String: CGImage] = [:]

    private func likeImage(liked: Bool, scale: CGFloat) -> CGImage? {
        let key = "\(liked)-\(self.effectiveAppearance.name.rawValue)-\(scale)"
        if let cached = Self.likeImages[key] {
            return cached
        }
        let symbol = liked ? "hand.thumbsup.fill" : "hand.thumbsup"
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
            .applying(.init(paletteColors: [liked ? TuneTheme.AppKit.ink : TuneTheme.AppKit.inkSecondary]))
        guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config) else {
            return nil
        }
        let rendered = HomeItemLayerImage.render(size: NSSize(width: Self.likeButtonSize, height: Self.likeButtonSize), scale: scale) { rect in
            // A rounded dark block keeps the glyph legible on bright artwork.
            TuneTheme.AppKit.background.withAlphaComponent(0.82).setFill()
            NSBezierPath(roundedRect: rect, xRadius: TuneTheme.Radius.small, yRadius: TuneTheme.Radius.small).fill()
            let size = image.size
            image.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height))
        }
        Self.likeImages[key] = rendered
        return rendered
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // Text colors are dynamic but baked into the text bitmap (re-resolved
        // by `updateLayer`); the layer images resolve system colors when rendered.
        self.needsDisplay = true
        if let item {
            self.artwork.refreshAppearance(for: item)
        }
        self.updateOverlayLayers()
    }

    /// The rank as zero-padded monospaced digits on a rounded background block,
    /// drawn into an artwork-sized bitmap inset from the bottom-leading corner
    /// (the canvas carries the inset on both sides, so RTL gravity mirrors it).
    private static func rankImage(_ rank: Int, scale: CGFloat) -> CGImage? {
        let text = rank < 10 ? "0\(rank)" : "\(rank)"
        let string = NSAttributedString(string: text, attributes: [
            .font: TuneTheme.AppKit.display,
            .foregroundColor: TuneTheme.AppKit.ink,
        ])
        let textSize = string.size()
        let inset = Self.playOverlayInset
        let block = NSSize(width: ceil(textSize.width) + 16, height: ceil(textSize.height) + 4)
        let canvas = NSSize(width: max(block.width + 2 * inset, 1), height: Self.artworkHeight)
        let image = HomeItemLayerImage.render(size: canvas, scale: scale) { _ in
            // Unflipped context: y = 0 is the artwork's bottom edge.
            let blockRect = NSRect(origin: NSPoint(x: inset, y: inset), size: block)
            TuneTheme.AppKit.background.setFill()
            NSBezierPath(roundedRect: blockRect, xRadius: TuneTheme.Radius.control, yRadius: TuneTheme.Radius.control).fill()
            string.draw(at: NSPoint(x: inset + 8, y: inset + 2))
        }
        return image
    }

    /// The mono VIDEO tag's frame: top-leading, opposite the like control.
    private func videoTagFrame(width: CGFloat) -> NSRect {
        let size = Self.videoTagSize
        let inset = Self.playOverlayInset
        return NSRect(
            x: self.isRightToLeft ? width - inset - size.width : inset,
            y: inset,
            width: size.width,
            height: size.height
        )
    }

    private static var videoTagString: NSAttributedString {
        NSAttributedString(string: TuneVideoTag.text, attributes: [
            .font: TuneTheme.AppKit.data,
            .foregroundColor: TuneTheme.AppKit.ink,
            .kern: 0.6,
        ])
    }

    /// Same metrics as the SwiftUI `TuneVideoTag`: 6 pt side and 2 pt vertical padding.
    static var videoTagSize: NSSize {
        let textSize = self.videoTagString.size()
        return NSSize(width: ceil(textSize.width) + 12, height: ceil(textSize.height) + 4)
    }

    private static var videoTagImages: [CGFloat: CGImage] = [:]

    private static func videoTagImage(scale: CGFloat) -> CGImage? {
        if let cached = self.videoTagImages[scale] {
            return cached
        }
        let string = self.videoTagString
        let rendered = HomeItemLayerImage.render(size: self.videoTagSize, scale: scale) { rect in
            TuneTheme.AppKit.background.withAlphaComponent(0.82).setFill()
            NSBezierPath(roundedRect: rect, xRadius: TuneTheme.Radius.small, yRadius: TuneTheme.Radius.small).fill()
            string.draw(at: NSPoint(x: 6, y: 2))
        }
        self.videoTagImages[scale] = rendered
        return rendered
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        self.menuProvider?() ?? super.menu(for: event)
    }

    // MARK: Configuration

    func configure(
        item: HomeSectionItem,
        rank: Int?,
        allowsLikeActions: Bool,
        playlistPlayAction: (() -> Void)?,
        environment: EnvironmentValues
    ) {
        let hasSamePlayAction = (self.playlistPlayAction == nil) == (playlistPlayAction == nil)
        let directionChanged = self.environment.layoutDirection != environment.layoutDirection
        self.environment = environment
        self.playlistPlayAction = playlistPlayAction
        if directionChanged {
            self.needsLayout = true
            self.needsDisplay = true
            self.updateOverlayLayers()
            self.noteFocusRingMaskChanged()
        }
        if self.item?.hasSameCardContent(as: item) == true,
           self.rank == rank,
           self.allowsLikeActions == allowsLikeActions,
           hasSamePlayAction
        {
            // The hosted overlay carries the forwarded environment; keep it
            // current if it is showing.
            if self.isHovered {
                self.updatePlayOverlay()
            }
            return
        }
        let sameSong = self.item?.id == item.id
        self.item = item
        self.rank = rank
        self.allowsLikeActions = allowsLikeActions
        self.setLikeFocused(self.isLikeFocused)
        self.imageLoadTask?.cancel()
        self.imageLoadTask = nil

        self.artwork.configure(item: item)
        // Like state is pushed by the shelf; keep it across a metadata-only
        // refresh of the same song so the card doesn't flash to "unliked".
        if !sameSong {
            self.isLiked = false
            // A card that changes song drops its hover; a metadata refresh of
            // the same song keeps it (the shelf still tracks it as hovered).
            self.setHovered(false, animated: false)
        } else if self.isHovered {
            // Width or environment may have changed: re-place the overlay.
            self.updatePlayOverlay()
        }
        self.loadArtwork(for: item)
        self.updateOverlayLayers()
        self.needsLayout = true
        self.needsDisplay = true

        let subtitle = item.homeCardSubtitle ?? ""
        self.subtitle = subtitle
        self.caption = HomeCardCaption.make(for: item)
        var accessibilityLabel = rank.map { String(localized: "Number \($0), \(item.title)") } ?? item.title
        if !subtitle.isEmpty {
            accessibilityLabel += ", \(subtitle)"
        }
        if self.isExplicit {
            accessibilityLabel += ", \(String(localized: "Explicit"))"
        }
        if item.isVideoSong {
            accessibilityLabel += ", \(String(localized: "Video"))"
        }
        self.setAccessibilityLabel(accessibilityLabel)
        self.updateAccessibilityActions()
    }

    /// Called on click, Return/Space, or an accessibility press.
    var activateAction: (() -> Void)?

    private func updateAccessibilityActions() {
        var actions: [NSAccessibilityCustomAction] = []
        if let item, self.playlistPlayAction != nil {
            actions.append(NSAccessibilityCustomAction(name: String(localized: "Play \(item.title)")) { [weak self] in
                self?.playlistPlayAction?()
                return true
            })
        }
        if let item, case .song = item, self.allowsLikeActions {
            let name = self.isLiked ? String(localized: "Unlike") : String(localized: "Like")
            actions.append(NSAccessibilityCustomAction(name: name) { [weak self] in
                self?.toggleLike()
                return true
            })
        }
        self.setAccessibilityCustomActions(actions)
    }

    override func accessibilityPerformPress() -> Bool {
        guard self.activateAction != nil else { return false }
        self.activateAction?()
        return true
    }

    // MARK: Keyboard

    /// Like AppKit's own buttons, cards join the key view loop only under Full
    /// Keyboard Access: with hundreds of cards alive, unconditional first-responder
    /// status made every shelf re-attach rebuild the window's key loop.
    override var acceptsFirstResponder: Bool {
        NSApp.isFullKeyboardAccessEnabled
    }

    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        self.setLikeFocused(self.window?.keyViewSelectionDirection == .selectingPrevious)
        self.scrollToVisible(self.bounds)
        return true
    }

    override func resignFirstResponder() -> Bool {
        guard super.resignFirstResponder() else { return false }
        self.setLikeFocused(false)
        return true
    }

    override var focusRingMaskBounds: NSRect {
        if self.isLikeFocused, let likeButtonFrame {
            return likeButtonFrame
        }
        guard let item else { return .zero }
        return NSRect(x: 0, y: 0, width: Self.width(for: item), height: Self.artworkHeight)
    }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: self.focusRingMaskBounds, xRadius: Self.cornerRadius, yRadius: Self.cornerRadius).fill()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard self.window?.firstResponder === self, event.keyCode == 49,
              event.modifierFlags.isDisjoint(with: [.command, .control, .option, .shift])
        else { return super.performKeyEquivalent(with: event) }
        // Focused controls handle Space before the app's Play/Pause shortcut.
        self.keyDown(with: event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 48, event.modifierFlags.isDisjoint(with: [.command, .control, .option]) {
            self.moveKeyboardFocus(backwards: event.modifierFlags.contains(.shift))
            return
        }
        switch event.keyCode {
        case 36, 76, 49: // Return, Enter, Space
            if self.isLikeFocused {
                self.likeAction?()
            } else {
                self.activateAction?()
            }
        default:
            super.keyDown(with: event)
        }
    }

    /// Two keyboard targets share the card's single view. Tab visits the like
    /// control before moving to the next card; Shift-Tab reverses that order.
    private func moveKeyboardFocus(backwards: Bool) {
        if backwards {
            if self.isLikeFocused {
                self.setLikeFocused(false)
            } else {
                self.window?.selectPreviousKeyView(self)
                if self.window?.firstResponder === self {
                    self.setLikeFocused(true)
                }
            }
        } else if self.supportsLikeAction, !self.isLikeFocused {
            self.setLikeFocused(true)
        } else {
            self.setLikeFocused(false)
            self.window?.selectNextKeyView(self)
        }
    }

    private func setLikeFocused(_ focused: Bool) {
        let focused = focused && self.supportsLikeAction
        guard focused != self.isLikeFocused else { return }
        self.isLikeFocused = focused
        self.updateOverlayLayers()
        self.noteFocusRingMaskChanged()
    }

    private var isExplicit: Bool {
        if case let .song(song) = self.item {
            return song.isExplicit == true
        }
        return false
    }

    private func loadArtwork(for item: HomeSectionItem) {
        let urls = Self.thumbnailURLs(for: item)
        guard !urls.isEmpty else { return }
        let targetSize = Self.artworkTargetSize(for: item)
        // A memory-cache hit is applied synchronously with no fade, so a
        // rebuilt shelf shows its artwork in the same frame it appears.
        if let url = urls.first, let cached = ImageCache.shared.cachedImage(for: url, targetSize: targetSize) {
            self.artwork.setImage(cached, animated: false)
            return
        }
        let itemID = item.id
        self.imageLoadTask = Task { [weak self] in
            for url in urls {
                if let image = await ImageCache.shared.image(for: url, targetSize: targetSize) {
                    guard !Task.isCancelled, let self, self.item?.id == itemID else { return }
                    self.artwork.setImage(image, animated: !self.environment.accessibilityReduceMotion)
                    return
                }
                if Task.isCancelled {
                    return
                }
            }
        }
    }

    /// The decode size `loadArtwork` requests for an item, in points.
    static func artworkTargetSize(for item: HomeSectionItem) -> CGSize {
        CGSize(width: self.width(for: item), height: self.artworkHeight)
    }

    /// Primary artwork URLs grouped by decode size, matching `loadArtwork`'s first
    /// request so a prefetch lands in the exact memory-cache entry a cell reads.
    static func prefetchRequests(for items: some Sequence<HomeSectionItem>) -> [(CGSize, [URL])] {
        // Only two sizes exist (square and wide video), so a linear scan beats hashing CGSize.
        var groups: [(CGSize, [URL])] = []
        for item in items {
            guard let url = self.thumbnailURLs(for: item).first else { continue }
            let size = self.artworkTargetSize(for: item)
            if let index = groups.firstIndex(where: { $0.0 == size }) {
                groups[index].1.append(url)
            } else {
                groups.append((size, [url]))
            }
        }
        return groups
    }

    /// Same candidate order as `HomeSectionItemCard`: wide video thumbnail first
    /// for video songs, then the standard artwork, then the fallback.
    static func thumbnailURLs(for item: HomeSectionItem) -> [URL] {
        var candidates: [URL?] = []
        if item.isVideoSong, case let .song(song) = item {
            candidates = [song.wideHighQualityThumbnailURL, item.thumbnailURL?.highQualityThumbnailURL, song.fallbackThumbnailURL]
        } else {
            // Google-hosted covers are re-requested at the tile's 2× size.
            let highQuality = item.thumbnailURL?.highQualityThumbnailURL
            candidates = [highQuality?.tuneArtworkURL(side: Self.squareWidth), highQuality]
        }
        var seen = Set<URL>()
        return candidates.compactMap(\.self).filter { seen.insert($0).inserted }
    }

    // MARK: Like status

    /// Like status is observed once per shelf (see `HomeItemShelfView`) and
    /// pushed here, rather than registering an observation per card.
    func setLiked(_ liked: Bool) {
        guard liked != self.isLiked else { return }
        self.isLiked = liked
        self.updateOverlayLayers()
        self.updateAccessibilityActions()
    }

    func toggleLike() {
        guard let item, case let .song(song) = item, self.allowsLikeActions else { return }
        HapticService.success()
        let manager = SongLikeStatusManager.shared
        if self.isLiked {
            SongActionsHelper.unlikeSong(song, likeStatusManager: manager)
        } else {
            SongActionsHelper.likeSong(song, likeStatusManager: manager)
        }
    }

    // MARK: Hover

    func setHovered(_ hovered: Bool, animated: Bool) {
        guard hovered != self.isHovered || !animated else { return }
        self.isHovered = hovered
        self.artwork.setLifted(hovered, animated: animated)
        self.updatePlayOverlay()
        self.updateOverlayLayers()
    }

    /// The glass play icon is the one piece of SwiftUI on the card, hosted only
    /// while this card is hovered, so at most one such view exists per shelf.
    private func updatePlayOverlay() {
        guard let item, case .song = item, self.isHovered else {
            self.playOverlay?.removeFromSuperview()
            self.playOverlay = nil
            return
        }
        let side = Self.playOverlaySize
        let root = AnyView(
            SongCoverPlayOverlay(size: CGSize(width: side, height: side))
                .environment(\.self, self.environment)
        )
        let width = Self.width(for: item)
        let inset = Self.playOverlayInset
        let frame = NSRect(
            x: self.isRightToLeft ? width - inset - side : inset,
            y: Self.artworkHeight - inset - side,
            width: side,
            height: side
        )
        if let playOverlay {
            playOverlay.rootView = root
            playOverlay.frame = frame
        } else {
            let overlay = NSHostingView(rootView: root)
            overlay.sizingOptions = []
            overlay.frame = frame
            self.addSubview(overlay)
            self.playOverlay = overlay
        }
    }

    // MARK: Drawing

    private static let titleFont = TuneTheme.AppKit.bodyMedium
    private static let subtitleFont = TuneTheme.AppKit.body
    private static let metaFont = TuneTheme.AppKit.data
    private static let badgeFont = NSFont.systemFont(ofSize: 8, weight: .semibold)

    override var wantsUpdateLayer: Bool {
        true
    }

    override func updateLayer() {
        guard let item else {
            self.setTextImage(nil, key: nil)
            return
        }
        let scale = self.window?.backingScaleFactor ?? 2
        let width = Self.width(for: item)
        let caption = self.caption
        let isRightToLeft = self.isRightToLeft
        let isExplicit = self.isExplicit
        // The bitmap is reused whenever this key matches, so it must name every
        // input `drawText` reads; a new input missing here shows stale text.
        let key = [
            item.displayTitle, caption.text, caption.meta ?? "", "\(isExplicit)", "\(width)", "\(isRightToLeft)",
            self.effectiveAppearance.name.rawValue, "\(scale)",
        ].joined(separator: "\u{1F}")
        guard key != self.textLayerKey else { return }
        var image = Self.textImages.object(forKey: key as NSString)
        if image == nil {
            self.effectiveAppearance.performAsCurrentDrawingAppearance {
                // Only the band below the artwork holds text.
                let size = NSSize(width: width, height: Self.height - Self.artworkHeight)
                // Every color `drawText` sets is a neutral gray, so gray + alpha
                // is lossless, except for color emoji in YouTube titles.
                let grayscale = !Self.mayContainColorGlyphs(item.displayTitle + caption.text)
                image = HomeItemLayerImage.render(size: size, scale: scale, flipped: true, grayscale: grayscale) { _ in
                    NSGraphicsContext.current?.cgContext.translateBy(x: 0, y: -Self.artworkHeight)
                    Self.drawText(for: item, caption: caption, width: width, isExplicit: isExplicit, isRightToLeft: isRightToLeft)
                }
            }
            if let image {
                Self.textImages.setObject(image, forKey: key as NSString, cost: image.bytesPerRow * image.height)
            }
        }
        // A failed render records no key, so the next display pass retries it.
        self.setTextImage(image, key: image == nil ? nil : key, scale: scale)
    }

    /// Swaps the text bitmap without the standalone layer's implicit
    /// `contents` fade. A nil key makes the next display pass resolve it again.
    private func setTextImage(_ image: CGImage?, key: String?, scale: CGFloat? = nil) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.textLayer.contents = image
        if let scale {
            self.textLayer.contentsScale = scale
        }
        CATransaction.commit()
        self.textLayerKey = key
    }

    /// Emoji-presentation characters, any character followed by the emoji
    /// variation selector, and supplementary-plane emoji draw as color glyphs.
    /// The last covers text-default emoji such as 🎙 (U+1F399), which CoreText
    /// still draws from Apple Color Emoji; text-default symbols below U+1F000
    /// (♥, ▶, ™) draw from monochrome fonts.
    static func mayContainColorGlyphs(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            scalar.value == 0xFE0F || scalar.properties.isEmojiPresentation
                || (scalar.value >= 0x1F000 && scalar.properties.isEmoji)
        }
    }

    /// Rendered text bitmaps shared across cells, so a shelf that SwiftUI
    /// rebuilds reuses its cards' text instead of typesetting it again.
    private static let textImages: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.totalCostLimit = 24 * 1024 * 1024
        return cache
    }()

    private static func drawText(for item: HomeSectionItem, caption: HomeCardCaption, width: CGFloat, isExplicit: Bool, isRightToLeft: Bool) {
        let textTop = Self.artworkHeight + 8
        let badgeSize: CGFloat = 12
        let titleMaxWidth = width - (isExplicit ? badgeSize + 6 : 0)

        // Title: up to two lines, last line truncated, like the SwiftUI card.
        // Word-wrapping paragraph + `truncatesLastVisibleLine` gives the
        // ellipsis on line two; a tail-truncating paragraph would force one line.
        let wrapping = NSMutableParagraphStyle()
        wrapping.lineBreakMode = .byWordWrapping
        wrapping.alignment = isRightToLeft ? .right : .left
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        paragraph.alignment = wrapping.alignment
        let title = NSAttributedString(string: item.displayTitle, attributes: [
            .font: Self.titleFont,
            .foregroundColor: TuneTheme.AppKit.ink,
            .paragraphStyle: wrapping,
        ])
        let titleLineHeight = ceil(Self.titleFont.ascender - Self.titleFont.descender + Self.titleFont.leading)
        let titleBounds = title.boundingRect(
            with: NSSize(width: titleMaxWidth, height: titleLineHeight * 2),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
        )
        let titleRect = NSRect(
            x: isRightToLeft ? width - titleMaxWidth : 0,
            y: textTop, width: titleMaxWidth, height: min(ceil(titleBounds.height), titleLineHeight * 2)
        )
        title.draw(with: titleRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])

        if isExplicit {
            let titleWidth = min(ceil(titleBounds.width), titleMaxWidth)
            let badgeX = isRightToLeft ? width - titleWidth - 6 - badgeSize : titleWidth + 6
            let badgeRect = NSRect(x: badgeX, y: textTop + (titleLineHeight - badgeSize) / 2, width: badgeSize, height: badgeSize)
            TuneTheme.AppKit.inkMuted.setFill()
            NSBezierPath(rect: badgeRect).fill()
            let badgeText = NSAttributedString(string: String(localized: "E"), attributes: [
                .font: Self.badgeFont,
                .foregroundColor: TuneTheme.AppKit.background,
            ])
            let badgeTextSize = badgeText.size()
            badgeText.draw(at: NSPoint(
                x: badgeRect.midX - badgeTextSize.width / 2,
                y: badgeRect.midY - badgeTextSize.height / 2
            ))
        }

        // Caption line: muted text, and a dim monospaced tag on the trailing edge.
        let captionTop = titleRect.maxY + 3
        let captionHeight = ceil(Self.subtitleFont.ascender - Self.subtitleFont.descender) + 2
        var textWidth = width
        if let meta = caption.meta, !meta.isEmpty {
            let metaString = NSAttributedString(string: meta, attributes: [
                .font: Self.metaFont,
                .foregroundColor: TuneTheme.AppKit.inkDim,
            ])
            let metaWidth = min(ceil(metaString.size().width), width / 2)
            let metaHeight = ceil(Self.metaFont.ascender - Self.metaFont.descender)
            // Baseline-align the 11 pt tag with the 13 pt caption.
            let metaY = captionTop + (Self.subtitleFont.ascender - Self.metaFont.ascender)
            let metaRect = NSRect(x: isRightToLeft ? 0 : width - metaWidth, y: metaY, width: metaWidth, height: metaHeight)
            metaString.draw(with: metaRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            textWidth = max(0, width - metaWidth - 8)
        }
        if !caption.text.isEmpty, textWidth > 0 {
            let subtitleString = NSAttributedString(string: caption.text, attributes: [
                .font: Self.subtitleFont,
                .foregroundColor: TuneTheme.AppKit.inkMuted,
                .paragraphStyle: paragraph,
            ])
            let subtitleRect = NSRect(x: isRightToLeft ? width - textWidth : 0, y: captionTop, width: textWidth, height: captionHeight)
            subtitleString.draw(with: subtitleRect, options: [.usesLineFragmentOrigin])
        }
    }
}

// MARK: - HomeItemArtworkLayers

/// Artwork layer stack (C2): a rounded (continuous) clipping content layer with the
/// placeholder fill, the placeholder icon, the decoded bitmap (aspect fill —
/// square covers and 16:9 video crops alike), and a 1 px inset edge that
/// brightens on hover instead of the old scale-and-shadow lift.
@MainActor
private final class HomeItemArtworkLayers {
    /// Carries the hover lift. Its own layer because it needs a centered
    /// anchor point, which AppKit view layers don't have.
    let liftLayer = CALayer()
    private let contentLayer = CALayer()
    private let gradientLayer = CAGradientLayer()
    private let iconLayer = CALayer()
    private let imageLayer = CALayer()
    private let edgeLayer = CALayer()
    private var placeholderSymbolName: String?

    init() {
        self.liftLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        self.edgeLayer.borderWidth = 1
        self.edgeLayer.borderColor = TuneTheme.AppKit.artworkEdge.cgColor
        // The edge follows the artwork's rounded shape.
        self.edgeLayer.cornerRadius = HomeItemCell.cornerRadius
        self.edgeLayer.cornerCurve = .continuous

        self.contentLayer.cornerRadius = HomeItemCell.cornerRadius
        self.contentLayer.cornerCurve = .continuous
        self.contentLayer.masksToBounds = true
        self.gradientLayer.startPoint = CGPoint(x: 0, y: 0)
        self.gradientLayer.endPoint = CGPoint(x: 1, y: 1)
        self.iconLayer.contentsGravity = .center
        self.iconLayer.contentsScale = 2
        self.imageLayer.contentsGravity = .resizeAspectFill
        self.contentLayer.addSublayer(self.gradientLayer)
        self.contentLayer.addSublayer(self.iconLayer)
        self.contentLayer.addSublayer(self.imageLayer)
        self.contentLayer.addSublayer(self.edgeLayer)
        self.liftLayer.addSublayer(self.contentLayer)
    }

    func layout(in frame: CGRect, scale: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let bounds = CGRect(origin: .zero, size: frame.size)
        self.liftLayer.bounds = bounds
        self.liftLayer.position = CGPoint(x: frame.midX, y: frame.midY)
        self.contentLayer.frame = bounds
        self.gradientLayer.frame = bounds
        self.imageLayer.frame = bounds
        self.edgeLayer.frame = bounds
        self.iconLayer.frame = bounds
        self.imageLayer.contentsScale = scale
        if self.iconLayer.contentsScale != scale {
            self.iconLayer.contentsScale = scale
            if let placeholderSymbolName {
                self.iconLayer.contents = Self.placeholderIcon(named: placeholderSymbolName, scale: scale)
            }
        }
        CATransaction.commit()
    }

    func configure(item: HomeSectionItem) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.imageLayer.contents = nil
        self.imageLayer.isHidden = true
        self.gradientLayer.isHidden = false
        // Every tile is an aspect-fill crop; video frames fill their 16:9 tile.
        self.imageLayer.contentsGravity = .resizeAspectFill
        self.gradientLayer.colors = Self.placeholderColors(for: item).map(\.cgColor)
        let symbol = Self.placeholderSymbol(for: item)
        self.placeholderSymbolName = symbol
        self.iconLayer.contents = Self.placeholderIcon(named: symbol, scale: self.iconLayer.contentsScale)
        // A mood card's color is its artwork, not a loading state: no placeholder glyph.
        self.iconLayer.isHidden = Self.moodColor(for: item) != nil
        CATransaction.commit()
    }

    /// Re-resolves the layer colors. The C2 palette is fixed, so this only
    /// re-applies them (kept for appearance-change callers).
    func refreshAppearance(for item: HomeSectionItem) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.gradientLayer.colors = Self.placeholderColors(for: item).map(\.cgColor)
        CATransaction.commit()
    }

    func setImage(_ image: NSImage, animated: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.imageLayer.contents = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        self.imageLayer.isHidden = false
        self.iconLayer.isHidden = true
        // Aspect-fitted video artwork still needs its backdrop in the margins.
        self.gradientLayer.isHidden = self.imageLayer.contentsGravity != .resizeAspect
        CATransaction.commit()
        guard animated else { return }
        // Match the SwiftUI card's crossfade on a fresh load.
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.25
        self.imageLayer.add(fade, forKey: "fadeIn")
    }

    /// Hover: the inset edge brightens to ink. No scale, no shadow (C2 is flat).
    func setLifted(_ lifted: Bool, animated: Bool) {
        let apply = {
            self.edgeLayer.borderColor = lifted
                ? TuneTheme.AppKit.ink.withAlphaComponent(0.7).cgColor
                : TuneTheme.AppKit.artworkEdge.cgColor
        }
        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(0.25)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        } else {
            CATransaction.setDisableActions(true)
        }
        apply()
        CATransaction.commit()
    }

    // MARK: Placeholder

    private static func placeholderSymbol(for item: HomeSectionItem) -> String {
        switch item {
        case .song: item.isVideoSong ? "play.rectangle" : "music.note"
        case .album: "square.stack"
        case .playlist: "music.note.list"
        case .artist: "person.fill"
        }
    }

    /// Same scheme as `HomeSectionItemCard`: mood cards keep the API color
    /// (their only artwork); everything else is the flat raised fill.
    private static func placeholderColors(for item: HomeSectionItem) -> [NSColor] {
        if let base = Self.moodColor(for: item) {
            // Toned toward the page so a row of API colors doesn't glare on near-black
            // (and the oranges don't read as the now-playing accent).
            let toned = base.blended(withFraction: 0.35, of: TuneTheme.AppKit.raised) ?? base
            return [toned, toned]
        }
        return [TuneTheme.AppKit.raised, TuneTheme.AppKit.raised]
    }

    /// The API color of a mood/genre card (sent as a `#RRGGBB` description), if any.
    private static func moodColor(for item: HomeSectionItem) -> NSColor? {
        guard case let .playlist(playlist) = item,
              let colorHex = playlist.description,
              colorHex.hasPrefix("#"),
              let color = Color(hex: colorHex)
        else { return nil }
        return NSColor(color)
    }

    /// Tinted symbol bitmaps, rendered once per symbol and backing scale.
    private static var placeholderIcons: [String: CGImage] = [:]

    private static func placeholderIcon(named symbol: String, scale: CGFloat) -> CGImage? {
        let key = "\(symbol)-\(scale)"
        if let cached = self.placeholderIcons[key] {
            return cached
        }
        let config = NSImage.SymbolConfiguration(pointSize: 28, weight: .light)
        guard let icon = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config) else {
            return nil
        }
        let tinted = HomeItemLayerImage.render(size: icon.size, scale: scale) { rect in
            icon.draw(in: rect)
            TuneTheme.AppKit.inkDim.set()
            rect.fill(using: .sourceAtop)
        }
        self.placeholderIcons[key] = tinted
        return tinted
    }
}

// MARK: - HomeItemLayerImage

@MainActor
private enum HomeItemLayerImage {
    /// Produces a bitmap with an explicit pixels-per-point ratio for CALayer.
    /// `grayscale` halves the bitmap for content drawn only in neutral colors.
    static func render(
        size: NSSize,
        scale: CGFloat,
        flipped: Bool = false,
        grayscale: Bool = false,
        draw: (NSRect) -> Void
    ) -> CGImage? {
        let bounds = NSRect(x: 0, y: 0, width: ceil(size.width), height: ceil(size.height))
        guard let colorSpace = CGColorSpace(name: grayscale ? CGColorSpace.genericGrayGamma2_2 : CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: Int(bounds.width * scale), height: Int(bounds.height * scale),
                  bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        context.scaleBy(x: scale, y: scale)
        if flipped {
            context.translateBy(x: 0, y: bounds.height)
            context.scaleBy(x: 1, y: -1)
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: flipped)
        defer { NSGraphicsContext.restoreGraphicsState() }
        draw(bounds)
        return context.makeImage()
    }
}
