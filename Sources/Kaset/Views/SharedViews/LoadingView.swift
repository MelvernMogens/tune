import SwiftUI

// MARK: - FixedProgressView

/// A ProgressView wrapper with explicit frame sizing to prevent AppKit Auto Layout constraint warnings.
/// The standard ProgressView on macOS can produce spurious warnings like:
/// "has a maximum length that doesn't satisfy min <= max"
/// This wrapper provides a fixed frame to avoid these layout ambiguity issues.
struct FixedProgressView: View {
    let controlSize: ControlSize
    let scale: CGFloat

    init(controlSize: ControlSize = .regular, scale: CGFloat = 1.0) {
        self.controlSize = controlSize
        self.scale = scale
    }

    private var frameSize: CGFloat {
        switch self.controlSize {
        case .mini:
            return 12 * self.scale
        case .small:
            return 16 * self.scale
        case .regular:
            return 20 * self.scale
        case .large:
            return 24 * self.scale
        case .extraLarge:
            return 32 * self.scale
        @unknown default:
            return 20 * self.scale
        }
    }

    var body: some View {
        ProgressView()
            .controlSize(self.controlSize)
            .scaleEffect(self.scale)
            .frame(width: self.frameSize, height: self.frameSize)
    }
}

// MARK: - LoadingView

/// Reusable loading indicator view with optional message.
/// Includes a pulsing animation for visual feedback.
struct LoadingView: View {
    /// The page shape the skeleton imitates.
    enum Layout {
        /// A quiet centered progress mark with a mono caption (sheets, YouTube pages,
        /// anything without a known shape).
        case spinner
        /// Title bar over track-like rows (playlists, search, artist pages).
        case list
        /// A grid of rounded tiles (Library).
        case grid
    }

    let message: String

    /// Whether to show shelf skeletons (browse pages) instead of the `layout` skeleton.
    let showSkeleton: Bool

    /// Number of skeleton sections to show.
    let skeletonSectionCount: Int

    let layout: Layout

    init(
        _ message: String = String(localized: "Loading..."),
        showSkeleton: Bool = false,
        skeletonSectionCount: Int = 3,
        layout: Layout = .spinner
    ) {
        self.message = message
        self.showSkeleton = showSkeleton
        self.skeletonSectionCount = skeletonSectionCount
        self.layout = layout
    }

    var body: some View {
        if self.showSkeleton {
            self.skeletonContent
        } else {
            self.spinnerContent
        }
    }

    /// C2: never a bare spinner on a blank page. A rounded list skeleton (title bar over
    /// track-like rows) holds the page's shape; the message stays for VoiceOver.
    private var spinnerContent: some View {
        Group {
            switch self.layout {
            case .spinner:
                VStack(spacing: 12) {
                    FixedProgressView(controlSize: .small)
                    Text(self.message)
                        .font(TuneTheme.Typeface.data)
                        .textCase(.uppercase)
                        .foregroundStyle(TuneTheme.Palette.inkMuted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .list: SkeletonListPage()
            case .grid: SkeletonGridPage()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(self.message)
    }

    private var skeletonContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 48) {
                ForEach(0 ..< self.skeletonSectionCount, id: \.self) { _ in
                    SkeletonSectionView()
                }
            }
            .padding(.horizontal, TuneTheme.Spacing.gutter)
            .padding(.top, 32)
        }
        .scrollDisabled(true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(self.message)
    }
}

// MARK: - SkeletonListPage

/// Page-shaped list skeleton: a title bar and a column of rows at the shared row pitch,
/// laid out on the page gutters so the loaded content lands where the skeleton was.
struct SkeletonListPage: View {
    var rowCount = 10

    /// Varying title widths so the rows don't read as a barcode.
    private static let titleFractions: [CGFloat] = [0.42, 0.3, 0.36, 0.26, 0.4, 0.33, 0.28, 0.38, 0.31, 0.35]

    var body: some View {
        GeometryReader { proxy in
            let width = max(0, proxy.size.width - 2 * TuneTheme.Spacing.gutter)
            VStack(alignment: .leading, spacing: 0) {
                SkeletonView.rectangle(cornerRadius: TuneTheme.Radius.control)
                    .frame(width: min(320, width * 0.5), height: 32)
                    .padding(.bottom, 12)
                SkeletonView.rectangle()
                    .frame(width: min(180, width * 0.3), height: 12)
                    .padding(.bottom, 32)

                ForEach(0 ..< self.rowCount, id: \.self) { index in
                    HStack(spacing: 14) {
                        SkeletonView.rectangle()
                            .frame(width: 32, height: 32)
                        SkeletonView.rectangle()
                            .frame(width: width * Self.titleFractions[index % Self.titleFractions.count], height: 12)
                        Spacer(minLength: 0)
                        SkeletonView.rectangle()
                            .frame(width: 36, height: 10)
                    }
                    .frame(height: 40)
                    .opacity(1 - Double(index) * 0.07)
                }
            }
            .padding(.horizontal, TuneTheme.Spacing.gutter)
            .padding(.top, 32)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipped()
        }
    }
}

// MARK: - SkeletonGridPage

/// Grid skeleton: a row of filter-label bars over rounded tiles with two caption bars.
struct SkeletonGridPage: View {
    private static let tileSide: CGFloat = 160
    private static let spacing: CGFloat = 18

    var body: some View {
        GeometryReader { proxy in
            let width = max(0, proxy.size.width - 2 * TuneTheme.Spacing.gutter)
            let columns = max(1, Int((width + Self.spacing) / (Self.tileSide + Self.spacing)))
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 20) {
                    ForEach(0 ..< 4, id: \.self) { _ in
                        SkeletonView.rectangle()
                            .frame(width: 64, height: 10)
                    }
                }
                .frame(height: 28)
                ForEach(0 ..< 2, id: \.self) { row in
                    HStack(alignment: .top, spacing: Self.spacing) {
                        ForEach(0 ..< columns, id: \.self) { _ in
                            SkeletonCardView(width: Self.tileSide, height: Self.tileSide)
                        }
                    }
                    .opacity(row == 0 ? 1 : 0.6)
                }
            }
            .padding(.horizontal, TuneTheme.Spacing.gutter)
            .padding(.top, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipped()
        }
    }
}

// MARK: - HomeLoadingView

/// Home's loading state: the C2 hero shape (lead tile beside a 2×2 grid) followed by
/// shelf skeletons, on the same gutters as the loaded page.
struct HomeLoadingView: View {
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 48) {
                SkeletonHeroView()
                    .fadeIn(delay: 0)
                ForEach(0 ..< 2, id: \.self) { index in
                    SkeletonSectionView()
                        .fadeIn(delay: Double(index + 1) * 0.1)
                }
            }
            .padding(.horizontal, TuneTheme.Spacing.gutter)
            .padding(.top, 32)
        }
        .scrollDisabled(true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Loading..."))
    }
}

// MARK: - SkeletonHeroView

/// The hero's skeleton: section title over a rule, a wide rounded lead block, and a 2×2
/// grid of rounded squares.
struct SkeletonHeroView: View {
    private static let tileSide: CGFloat = 150
    private static let gap: CGFloat = 16

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SkeletonView.rectangle(cornerRadius: TuneTheme.Radius.control)
                .frame(width: 260, height: 36)
                .padding(.bottom, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(TuneTheme.Palette.hairline)
                        .frame(height: 1)
                }

            HStack(alignment: .top, spacing: Self.gap) {
                SkeletonView.rectangle(cornerRadius: TuneTheme.Radius.hero)
                    .frame(maxWidth: .infinity)
                    .frame(height: 2 * Self.tileSide + Self.gap)
                Grid(horizontalSpacing: Self.gap, verticalSpacing: Self.gap) {
                    ForEach(0 ..< 2, id: \.self) { _ in
                        GridRow {
                            ForEach(0 ..< 2, id: \.self) { _ in
                                SkeletonView.rectangle(cornerRadius: TuneTheme.Radius.artwork)
                                    .frame(width: Self.tileSide, height: Self.tileSide)
                            }
                        }
                    }
                }
            }
        }
    }
}

#Preview {
    VStack {
        LoadingView("Loading your music...")
        Divider()
        LoadingView("Loading...", showSkeleton: true, skeletonSectionCount: 2)
    }
    .frame(width: 600, height: 800)
}
