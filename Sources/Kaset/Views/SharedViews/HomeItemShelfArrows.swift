import AppKit

// MARK: - HomeItemShelfContainerView

/// Hosts the shelf's scroll view and its two paging arrows.
///
/// The arrows are plain layer-backed AppKit views (a small rounded square with
/// a hairline edge, no glass, no shadow), so Core Animation composites them
/// without main-thread work while the page scrolls. Arrows sit on physical
/// sides; the shelf maps them to leading/trailing for paging and right-to-left
/// layouts.
@MainActor
final class HomeItemShelfContainerView: NSView {
    enum Side {
        case left
        case right
    }

    /// Hit-and-layout frame. The visible square is ``arrowSquareSize``, centered.
    static let arrowSize: CGFloat = 38
    static let arrowSquareSize: CGFloat = 28

    /// Called with the physical side of the arrow that was pressed.
    var pageHandler: ((Side) -> Void)?

    private weak var scrollView: NSScrollView?
    private var contentInset: CGFloat = 0
    private let leftArrow = HomeItemShelfArrowView(side: .left)
    private let rightArrow = HomeItemShelfArrowView(side: .right)
    private var isHovering = false
    /// Masks the scroll view so cards end at the content gutters: nothing draws
    /// past `contentInset` on either side, and a side with more cards beyond it
    /// fades out over ``edgeFadeWidth`` instead of a hard cut.
    private let edgeMask = CAGradientLayer()
    private var fadesLeft = false
    private var fadesRight = false

    /// Width of the fade where a shelf continues past its visible edge.
    static let edgeFadeWidth: CGFloat = 36

    override var isFlipped: Bool {
        true
    }

    func install(scrollView: NSScrollView, contentInset: CGFloat) {
        self.scrollView = scrollView
        self.contentInset = contentInset
        self.addSubview(scrollView)
        scrollView.wantsLayer = true
        self.edgeMask.startPoint = CGPoint(x: 0, y: 0.5)
        self.edgeMask.endPoint = CGPoint(x: 1, y: 0.5)
        self.edgeMask.colors = [
            NSColor.clear.cgColor, NSColor.clear.cgColor, NSColor.black.cgColor,
            NSColor.black.cgColor, NSColor.clear.cgColor, NSColor.clear.cgColor,
        ]
        scrollView.layer?.mask = self.edgeMask
        for arrow in [self.leftArrow, self.rightArrow] {
            arrow.pressHandler = { [weak self] side in self?.pageHandler?(side) }
            arrow.focusHandler = { [weak self] in self?.updateProminence() }
            self.addSubview(arrow)
        }
    }

    /// Shelf label used in the arrows' accessibility labels, and whether to use
    /// the macOS 15 material instead of glass.
    func configure(shelfLabel: String, usesLegacyMaterial: Bool) {
        for arrow in [self.leftArrow, self.rightArrow] {
            arrow.configure(shelfLabel: shelfLabel, usesLegacyMaterial: usesLegacyMaterial)
        }
    }

    /// Shows or hides each arrow; `animated` fades and scales them like the
    /// SwiftUI transition they replace.
    func setArrows(left: Bool, right: Bool, animated: Bool) {
        self.leftArrow.setVisible(left, animated: animated)
        self.rightArrow.setVisible(right, animated: animated)
        if left != self.fadesLeft || right != self.fadesRight {
            self.fadesLeft = left
            self.fadesRight = right
            self.updateEdgeMask(animated: animated)
        }
        // Paging to an end hides the focused arrow. Hand focus to the other
        // one; once hidden, AppKit would move it to the next key view,
        // outside the shelf.
        if self.leftArrow.isFocused, !left, right {
            self.window?.makeFirstResponder(self.rightArrow)
        } else if self.rightArrow.isFocused, !right, left {
            self.window?.makeFirstResponder(self.leftArrow)
        }
    }

    /// Whether `point` (in this view's coordinates) lies between the content
    /// insets, where cards are visible. Outside it the mask hides them.
    func isInContentBand(_ point: NSPoint) -> Bool {
        point.x >= self.contentInset && point.x <= self.bounds.width - self.contentInset
    }

    /// Masked-off cards in the gutters take no clicks, menus or scrolls: those
    /// reach whatever is behind the shelf (the page).
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard self.isInContentBand(self.convert(point, from: self.superview)) else { return nil }
        return super.hitTest(point)
    }

    /// Physical arrow, for tests.
    func arrow(_ side: Side) -> HomeItemShelfArrowView {
        side == .left ? self.leftArrow : self.rightArrow
    }

    func isShowingArrow(_ side: Side) -> Bool {
        switch side {
        case .left: self.leftArrow.isVisible
        case .right: self.rightArrow.isVisible
        }
    }

    /// Pointer over the shelf raises both arrows to full prominence.
    func setHovering(_ hovering: Bool) {
        guard hovering != self.isHovering else { return }
        self.isHovering = hovering
        self.updateProminence()
    }

    /// Hovering the shelf or focusing either arrow raises both, like the
    /// SwiftUI controls.
    private func updateProminence() {
        let prominent = self.isHovering || self.leftArrow.isFocused || self.rightArrow.isFocused
        self.leftArrow.setShelfProminent(prominent)
        self.rightArrow.setShelfProminent(prominent)
    }

    /// A trackpad swipe that starts on an arrow still scrolls the shelf (or,
    /// for vertical gestures, the page via the document view's routing).
    override func scrollWheel(with event: NSEvent) {
        if let documentView = self.scrollView?.documentView {
            documentView.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }

    /// Gradient stops for a shelf `width` wide: clear outside the insets, a
    /// fade inside each edge that has more content beyond it, opaque between.
    static func edgeMaskLocations(width: CGFloat, inset: CGFloat, fadesLeft: Bool, fadesRight: Bool) -> [NSNumber] {
        guard width > 0, width.isFinite else { return [0, 0, 0, 1, 1, 1] }
        let inset = min(max(inset, 0), width / 2)
        let fade = min(Self.edgeFadeWidth, max(0, width / 2 - inset))
        let stops = [
            0,
            inset,
            inset + (fadesLeft ? fade : 0),
            width - inset - (fadesRight ? fade : 0),
            width - inset,
            width,
        ]
        return stops.map { NSNumber(value: Double(min(max($0 / width, 0), 1))) }
    }

    private func updateEdgeMask(animated: Bool) {
        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(0.2)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        } else {
            CATransaction.setDisableActions(true)
        }
        self.edgeMask.locations = Self.edgeMaskLocations(
            width: self.bounds.width,
            inset: self.contentInset,
            fadesLeft: self.fadesLeft,
            fadesRight: self.fadesRight
        )
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        self.scrollView?.frame = self.bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let layer = self.scrollView?.layer, layer.mask !== self.edgeMask {
            layer.mask = self.edgeMask
        }
        self.edgeMask.frame = self.scrollView?.layer?.bounds ?? self.bounds
        CATransaction.commit()
        self.updateEdgeMask(animated: false)
        let size = Self.arrowSize
        // Center on the artwork band rather than the whole card.
        let y = min((self.bounds.height - size) / 2, max(0, (HomeItemCell.artworkHeight - size) / 2))
        // Sit at the resting inset (not the column edge) so the arrows clear the
        // floating-sidebar band, mirroring the SwiftUI controls.
        self.leftArrow.frame = NSRect(x: self.contentInset + 4, y: y, width: size, height: size)
        self.rightArrow.frame = NSRect(x: self.bounds.width - self.contentInset - 4 - size, y: y, width: size, height: size)
    }
}

// MARK: - HomeItemShelfArrowView

/// One paging arrow: a rounded square with a chevron. Handles its own clicks,
/// Return/Space under Full Keyboard Access, focus ring and accessibility, so
/// the background and chevron subviews stay passive.
@MainActor
final class HomeItemShelfArrowView: NSView {
    var pressHandler: ((HomeItemShelfContainerView.Side) -> Void)?
    /// Called when this arrow gains or loses keyboard focus.
    var focusHandler: (() -> Void)?
    private(set) var isVisible = false
    private(set) var isFocused = false

    private let side: HomeItemShelfContainerView.Side
    private let chevron = NSImageView()
    private var background: NSView?
    private var shelfLabel: String?
    private var usesLegacyMaterial: Bool?
    private var isShelfProminent = false
    private var isPressed = false

    init(side: HomeItemShelfContainerView.Side) {
        self.side = side
        super.init(frame: .zero)
        self.wantsLayer = true
        self.isHidden = true
        self.alphaValue = 0
        self.focusRingType = .exterior

        let symbol = side == .left ? "chevron.left" : "chevron.right"
        let configuration = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        self.chevron.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        self.chevron.contentTintColor = TuneTheme.AppKit.ink
        self.chevron.imageScaling = .scaleNone

        // The C2 section header exposes the same paging buttons with the same
        // labels; VoiceOver gets those, not this hover-only duplicate.
        self.setAccessibilityElement(false)
        self.setAccessibilityRole(.button)
        self.setAccessibilityHelp(CarouselShelfPagingControls.accessibilityHint)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }

    /// Runs on every representable update, so both halves skip unchanged values.
    /// `usesLegacyMaterial` is accepted for API compatibility; C2 arrows are
    /// the same flat square on every OS.
    func configure(shelfLabel: String, usesLegacyMaterial: Bool) {
        if shelfLabel != self.shelfLabel {
            self.shelfLabel = shelfLabel
            self.setAccessibilityLabel(CarouselShelfPagingControls.accessibilityLabel(shelf: shelfLabel, isLeft: self.side == .left))
        }
        guard usesLegacyMaterial != self.usesLegacyMaterial else { return }
        self.usesLegacyMaterial = usesLegacyMaterial
        guard self.background == nil else { return }
        let background = NSView()
        background.wantsLayer = true
        background.layer?.backgroundColor = TuneTheme.AppKit.background.withAlphaComponent(0.88).cgColor
        background.layer?.borderColor = TuneTheme.AppKit.rule.cgColor
        background.layer?.borderWidth = 1
        background.layer?.cornerRadius = TuneTheme.Radius.control
        background.layer?.cornerCurve = .continuous
        background.addSubview(self.chevron)
        self.chevron.autoresizingMask = [.width, .height]
        self.addSubview(background)
        self.background = background
        self.needsLayout = true
    }

    /// The visible square, centered in the arrow's frame.
    private var squareRect: NSRect {
        let side = min(HomeItemShelfContainerView.arrowSquareSize, self.bounds.width, self.bounds.height)
        return NSRect(x: self.bounds.midX - side / 2, y: self.bounds.midY - side / 2, width: side, height: side)
    }

    // MARK: Visibility and prominence

    func setVisible(_ visible: Bool, animated: Bool) {
        guard visible != self.isVisible else { return }
        self.isVisible = visible
        if visible {
            self.isHidden = false
        }
        let alpha = self.targetAlpha
        guard animated else {
            self.applyProminence()
            self.alphaValue = alpha
            self.setScale(1)
            self.isHidden = !visible
            return
        }
        if visible {
            self.setScale(0.9)
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            self.animator().alphaValue = alpha
            self.applyProminence()
            self.setScale(visible ? self.restingScale : 0.9)
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isVisible else { return }
                // Hidden arrows leave hit testing and the key view loop.
                self.isHidden = true
            }
        }
    }

    func setShelfProminent(_ prominent: Bool) {
        guard prominent != self.isShelfProminent else { return }
        self.isShelfProminent = prominent
        self.animateProminence()
    }

    private var hasProminence: Bool {
        self.isShelfProminent || self.isFocused
    }

    /// C2: the section header carries the resting ‹ › controls, so in-shelf
    /// arrows only appear while the pointer is over the shelf (or on focus).
    static let restingAlpha: CGFloat = 0

    private var targetAlpha: CGFloat {
        guard self.isVisible else { return 0 }
        return self.hasProminence ? 1 : Self.restingAlpha
    }

    private var restingScale: CGFloat {
        self.isFocused ? 1.04 : 1
    }

    private func animateProminence() {
        guard self.isVisible else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            self.animator().alphaValue = self.targetAlpha
            self.applyProminence()
            self.setScale(self.restingScale)
        }
    }

    /// Prominence brightens the square's edge; there is no shadow in C2.
    private func applyProminence() {
        self.background?.layer?.borderColor = self.hasProminence
            ? TuneTheme.AppKit.inkMuted.cgColor
            : TuneTheme.AppKit.rule.cgColor
    }

    /// Scales around the center; AppKit pins view layers' anchor at the origin.
    private func setScale(_ scale: CGFloat) {
        let center = CGPoint(x: self.bounds.midX, y: self.bounds.midY)
        var transform = CATransform3DMakeTranslation(center.x, center.y, 0)
        transform = CATransform3DScale(transform, scale, scale, 1)
        transform = CATransform3DTranslate(transform, -center.x, -center.y, 0)
        self.layer?.transform = transform
    }

    override func layout() {
        super.layout()
        self.background?.frame = self.squareRect
        self.chevron.frame = self.background?.bounds ?? .zero
        self.setScale(self.isVisible ? self.restingScale : 0.9)
    }

    // MARK: Input

    /// The square and chevron are decoration; the arrow itself takes every event.
    override func hitTest(_ point: NSPoint) -> NSView? {
        // `point` is in the superview's coordinates. Only a showing arrow's
        // square is the button: clicks during the fade-out and in the frame's
        // margin reach the card beneath.
        // At rest the arrow is transparent (C2 header carries the controls), so
        // it only takes clicks while the shelf is hovered or the arrow focused.
        guard self.isVisible, self.hasProminence || Self.restingAlpha > 0,
              self.squareContains(self.convert(point, from: self.superview))
        else { return nil }
        return self
    }

    /// Whether `point`, in this view's coordinates, is inside the visible square.
    private func squareContains(_ point: NSPoint) -> Bool {
        self.squareRect.contains(point)
    }

    override func mouseDown(with _: NSEvent) {
        self.isPressed = true
        self.background?.alphaValue = 0.75
    }

    override func mouseDragged(with event: NSEvent) {
        let inside = self.squareContains(self.convert(event.locationInWindow, from: nil))
        self.background?.alphaValue = inside ? 0.75 : 1
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            self.isPressed = false
            self.background?.alphaValue = 1
        }
        guard self.isPressed, self.squareContains(self.convert(event.locationInWindow, from: nil)) else { return }
        self.press()
    }

    private func press() {
        self.pressHandler?(self.side)
    }

    /// A leaf button: the chevron's image cell would otherwise be exposed as
    /// an unlabeled image inside it.
    override func accessibilityChildren() -> [Any]? {
        []
    }

    override func accessibilityPerformPress() -> Bool {
        guard self.isVisible else { return false }
        self.press()
        return true
    }

    // MARK: Keyboard

    override var acceptsFirstResponder: Bool {
        // Keyboard focus only: an arrow focused by a click would keep Space,
        // which then pages instead of toggling Play/Pause.
        NSApp.isFullKeyboardAccessEnabled && self.isVisible && NSApp.currentEvent?.type != .leftMouseDown
    }

    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        self.isFocused = true
        self.animateProminence()
        self.focusHandler?()
        self.scrollToVisible(self.bounds)
        return true
    }

    override func resignFirstResponder() -> Bool {
        guard super.resignFirstResponder() else { return false }
        self.isFocused = false
        self.animateProminence()
        self.focusHandler?()
        return true
    }

    override var focusRingMaskBounds: NSRect {
        self.squareRect
    }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: self.squareRect, xRadius: TuneTheme.Radius.control, yRadius: TuneTheme.Radius.control).fill()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard self.window?.firstResponder === self, event.keyCode == 49,
              event.modifierFlags.isDisjoint(with: [.command, .control, .option, .shift])
        else { return super.performKeyEquivalent(with: event) }
        // Focused controls handle Space before the app's Play/Pause shortcut.
        self.press()
        return true
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76, 49: // Return, Enter, Space
            self.press()
        default:
            super.keyDown(with: event)
        }
    }
}
