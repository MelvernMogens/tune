import AppKit
import SwiftUI

// MARK: - HomeSwipePagingTracker

/// Turns scroll-wheel events over a paged section into at most one page turn
/// per gesture: a two-finger horizontal trackpad swipe, or a burst of
/// horizontal mouse-wheel ticks (Shift-scroll). Vertical gestures pass through
/// to the page, and a horizontal gesture's momentum tail is swallowed, never
/// turned into extra pages.
struct HomeSwipePagingTracker {
    enum Decision: Equatable {
        /// Not ours: deliver the event as usual.
        case pass
        /// Ours, but no page turn on this event.
        case consume
        /// Turn one page. `towardsRight` reveals the content on the right
        /// (fingers moved left under natural scrolling).
        case page(towardsRight: Bool)
    }

    private enum Axis {
        case undecided
        case horizontal
        case vertical
    }

    /// Horizontal travel (points) a trackpad swipe needs before it turns the page.
    static let threshold: CGFloat = 24
    /// Phase-less wheel ticks closer together than this are one gesture.
    static let wheelBurstGap: TimeInterval = 0.35

    private var axis: Axis = .undecided
    private var accumulated: CGFloat = 0
    private var hasPaged = false
    private var lastWheelTimestamp: TimeInterval?

    mutating func handle(
        phase: NSEvent.Phase,
        momentumPhase: NSEvent.Phase,
        deltaX: CGFloat,
        deltaY: CGFloat,
        timestamp: TimeInterval
    ) -> Decision {
        guard deltaX.isFinite, deltaY.isFinite else { return .pass }

        // Mouse wheels (and Shift-scroll) carry no phases.
        if phase.isEmpty, momentumPhase.isEmpty {
            guard deltaX != 0, abs(deltaX) > abs(deltaY) else { return .pass }
            let isNewBurst = self.lastWheelTimestamp.map { timestamp - $0 > Self.wheelBurstGap } ?? true
            self.lastWheelTimestamp = timestamp
            return isNewBurst ? .page(towardsRight: deltaX < 0) : .consume
        }

        if !phase.isDisjoint(with: [.mayBegin, .began]) {
            self.axis = .undecided
            self.accumulated = 0
            self.hasPaged = false
        }

        // Momentum after the fingers lift: never another page.
        if !momentumPhase.isEmpty {
            return self.axis == .horizontal ? .consume : .pass
        }

        if self.axis == .undecided {
            guard deltaX != 0 || deltaY != 0 else { return .pass }
            self.axis = abs(deltaX) > abs(deltaY) ? .horizontal : .vertical
        }
        guard self.axis == .horizontal else { return .pass }

        self.accumulated += deltaX
        if !self.hasPaged, abs(self.accumulated) >= Self.threshold {
            self.hasPaged = true
            return .page(towardsRight: self.accumulated < 0)
        }
        return .consume
    }
}

// MARK: - Swipe catcher

extension View {
    /// Pages this section on a horizontal trackpad swipe or Shift-scroll over it,
    /// one page per gesture. `onPage` receives the logical direction.
    func homeSwipePaging(isEnabled: Bool, onPage: @escaping (CarouselShelfDirection) -> Void) -> some View {
        self.background {
            HomeSwipeCatcher(isEnabled: isEnabled, onPage: onPage)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

/// An invisible view that watches the window's scroll-wheel events through a
/// local monitor and claims the horizontal ones that land inside its bounds.
/// A monitor rather than a hit-testing overlay, so clicks, hover and context
/// menus on the tiles underneath are untouched.
private struct HomeSwipeCatcher: NSViewRepresentable {
    let isEnabled: Bool
    let onPage: (CarouselShelfDirection) -> Void

    @Environment(\.layoutDirection) private var layoutDirection

    func makeNSView(context _: Context) -> HomeSwipeCatcherView {
        let view = HomeSwipeCatcherView()
        self.configure(view)
        return view
    }

    func updateNSView(_ view: HomeSwipeCatcherView, context _: Context) {
        self.configure(view)
    }

    static func dismantleNSView(_ view: HomeSwipeCatcherView, coordinator _: ()) {
        view.removeMonitor()
    }

    private func configure(_ view: HomeSwipeCatcherView) {
        view.isEnabled = self.isEnabled
        let layoutDirection = self.layoutDirection
        let onPage = self.onPage
        view.pageHandler = { towardsRight in
            onPage(CarouselShelfDirection(isLeft: !towardsRight, in: layoutDirection))
        }
    }
}

@MainActor
private final class HomeSwipeCatcherView: NSView {
    var isEnabled = false
    var pageHandler: ((Bool) -> Void)?

    private var monitor: Any?
    private var tracker = HomeSwipePagingTracker()
    /// Whether the current phased gesture began over this view; later events of
    /// the same gesture stay ours even if the pointer drifts out.
    private var ownsGesture = false

    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if self.window == nil {
            self.removeMonitor()
        } else {
            self.installMonitor()
        }
    }

    private func installMonitor() {
        guard self.monitor == nil else { return }
        self.monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            let phase = event.phase
            let momentum = event.momentumPhase
            let sample = HomeSwipeSample(
                windowNumber: event.window?.windowNumber,
                locationInWindow: event.locationInWindow,
                phase: phase,
                momentumPhase: momentum,
                deltaX: event.scrollingDeltaX,
                deltaY: event.scrollingDeltaY,
                timestamp: event.timestamp
            )
            let consumed = MainActor.assumeIsolated {
                self?.handle(sample) ?? false
            }
            return consumed ? nil : event
        }
    }

    func removeMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        self.monitor = nil
        self.ownsGesture = false
    }

    /// Whether the event was claimed (and so must not reach the page).
    private func handle(_ sample: HomeSwipeSample) -> Bool {
        guard self.isEnabled, let window = self.window, sample.windowNumber == window.windowNumber else { return false }
        let isPhased = !sample.phase.isEmpty || !sample.momentumPhase.isEmpty
        if !sample.phase.isDisjoint(with: [.mayBegin, .began]) || !isPhased {
            // A new gesture (or a lone wheel tick) belongs to whoever is under the pointer.
            self.ownsGesture = self.visibleRect.contains(self.convert(sample.locationInWindow, from: nil))
                && self.isFrontmost(at: sample.locationInWindow, in: window)
        }
        guard self.ownsGesture else { return false }

        let decision = self.tracker.handle(
            phase: sample.phase,
            momentumPhase: sample.momentumPhase,
            deltaX: sample.deltaX,
            deltaY: sample.deltaY,
            timestamp: sample.timestamp
        )
        switch decision {
        case .pass:
            return false
        case .consume:
            return true
        case let .page(towardsRight):
            self.pageHandler?(towardsRight)
            return true
        }
    }

    /// Whether nothing else sits over this section at `locationInWindow`: the
    /// toolbar, or an overlay with its own scrolling (queue panel, Now Playing
    /// lists, the video window's web view) must keep its swipes. SwiftUI draws
    /// the tiles inside the page's hosting views, so a hit on one of this view's
    /// ancestors, or on anything inside the same page scroll view, is the section.
    private func isFrontmost(at locationInWindow: NSPoint, in window: NSWindow) -> Bool {
        guard let contentView = window.contentView,
              let hit = (contentView.superview ?? contentView).hitTest(locationInWindow)
        else { return true }
        guard hit.isDescendant(of: contentView) else { return false }
        if hit === self || self.isDescendant(of: hit) {
            return true
        }
        if let scrollView = hit.enclosingScrollView {
            return self.isDescendant(of: scrollView)
        }
        return true
    }
}

/// The parts of a scroll-wheel event the catcher reads, copied off the event
/// so nothing non-Sendable crosses into the main-actor handler.
private struct HomeSwipeSample: Sendable {
    let windowNumber: Int?
    let locationInWindow: NSPoint
    let phase: NSEvent.Phase
    let momentumPhase: NSEvent.Phase
    let deltaX: CGFloat
    let deltaY: CGFloat
    let timestamp: TimeInterval
}

// MARK: - HomePagedStrip

/// Lays a section's pages side by side and slides between them: the page
/// change animates as a horizontal slide inside the section's bounds. Only the
/// current page takes clicks, hover and accessibility focus.
struct HomePagedStrip<Page: View>: View {
    let pageCount: Int
    let page: Int
    let width: CGFloat
    /// How far content may draw past the strip's sides (hover fills) before
    /// the slide clips it.
    var bleed: CGFloat = 8
    @ViewBuilder let content: (Int) -> Page

    /// Gap between neighbouring pages while they slide.
    static var pageGap: CGFloat {
        TuneTheme.Spacing.gutter
    }

    var body: some View {
        let pitch = self.width + 2 * self.bleed + Self.pageGap
        HStack(alignment: .top, spacing: Self.pageGap) {
            ForEach(0 ..< max(self.pageCount, 1), id: \.self) { index in
                self.content(index)
                    .frame(width: self.width, alignment: .topLeading)
                    .padding(.horizontal, self.bleed)
                    .allowsHitTesting(index == self.page)
                    .accessibilityHidden(index != self.page)
            }
        }
        .offset(x: -CGFloat(self.page) * pitch)
        .frame(width: self.width + 2 * self.bleed, alignment: .leading)
        .clipped()
        // Clipping doesn't clip hit testing; neighbours are already inert.
        .contentShape(Rectangle())
        .padding(.horizontal, -self.bleed)
    }
}

extension Animation {
    /// The slide between pages of a Home section.
    static let homePageSlide = Animation.smooth(duration: 0.38)
}
