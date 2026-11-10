import SwiftUI

// MARK: - HomeShelfPager

/// Paging state shared between a shelf and its C2 section header, so the header
/// can show "01—05 / 20" with ‹ › controls while the shelf owns the scrolling.
/// Writers only assign changed values, so scrolling doesn't churn observers.
@MainActor
@Observable
final class HomeShelfPager {
    private(set) var first = 0
    private(set) var last = 0
    private(set) var total = 0
    private(set) var canPageLeading = false
    private(set) var canPageTrailing = false

    @ObservationIgnored var pageHandler: ((CarouselShelfDirection) -> Void)?

    /// One-based inclusive range of items in view.
    func update(first: Int, last: Int, total: Int, canPageLeading: Bool, canPageTrailing: Bool) {
        if self.first != first { self.first = first }
        if self.last != last { self.last = last }
        if self.total != total { self.total = total }
        if self.canPageLeading != canPageLeading { self.canPageLeading = canPageLeading }
        if self.canPageTrailing != canPageTrailing { self.canPageTrailing = canPageTrailing }
    }

    func page(_ direction: CarouselShelfDirection) {
        self.pageHandler?(direction)
    }

    var rangeLabel: String? {
        guard self.total > 0, self.last > 0 else { return nil }
        return HomeShelfRange.label(first: self.first, last: self.last, total: self.total)
    }

    var isPageable: Bool {
        self.canPageLeading || self.canPageTrailing
    }
}

// MARK: - HomeSectionHeader

/// C2 section header: optional mono eyebrow, the title, a right-aligned mono
/// range with small ‹ › chevrons, and a rule underneath.
struct HomeSectionHeader<Title: View>: View {
    let accessibilityLabel: String
    var eyebrow: String?
    var pager: HomeShelfPager?
    @ViewBuilder let title: () -> Title

    @Environment(\.layoutDirection) private var layoutDirection

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: TuneTheme.Spacing.itemGap) {
            VStack(alignment: .leading, spacing: 10) {
                if let eyebrow, !eyebrow.isEmpty {
                    Text(eyebrow)
                        .font(TuneTheme.Typeface.data)
                        .textCase(.uppercase)
                        .foregroundStyle(TuneTheme.Palette.inkMuted)
                        .lineLimit(1)
                }
                self.title()
                    .foregroundStyle(TuneTheme.Palette.ink)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
            }

            Spacer(minLength: 0)

            if let pager {
                self.pagerControls(pager)
            }
        }
        .padding(.bottom, 10)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(TuneTheme.Palette.rule)
                .frame(height: 1)
        }
    }

    /// The same control set on every shelf: range plus ‹ › together, or nothing at all when
    /// the whole shelf fits on one page (a lone "01—02 / 02" with no arrows reads as broken).
    @ViewBuilder
    private func pagerControls(_ pager: HomeShelfPager) -> some View {
        if pager.isPageable {
            HStack(alignment: .center, spacing: 14) {
                if let rangeLabel = pager.rangeLabel {
                    Text(verbatim: rangeLabel)
                        .font(TuneTheme.Typeface.data)
                        .foregroundStyle(TuneTheme.Palette.inkMuted)
                        .accessibilityHidden(true)
                }
                HStack(spacing: 6) {
                    self.chevron(isLeft: true, pager: pager)
                    self.chevron(isLeft: false, pager: pager)
                }
            }
        }
    }

    private func chevron(isLeft: Bool, pager: HomeShelfPager) -> some View {
        let direction = CarouselShelfDirection(isLeft: isLeft, in: self.layoutDirection)
        let isEnabled = direction == .leading ? pager.canPageLeading : pager.canPageTrailing
        return Button {
            pager.page(direction)
        } label: {
            Image(systemName: isLeft ? "chevron.left" : "chevron.right")
                .font(TuneTheme.Typeface.label)
                .foregroundStyle(isEnabled ? TuneTheme.Palette.inkSecondary : TuneTheme.Palette.inkDim)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(CarouselShelfPagingControls.accessibilityLabel(shelf: self.accessibilityLabel, isLeft: isLeft))
        .accessibilityHint(CarouselShelfPagingControls.accessibilityHint)
    }
}

extension HomeSectionHeader where Title == HomeSectionTitleText {
    /// Plain C2 header: section-size title, or headline size for the hero.
    init(_ title: String, eyebrow: String? = nil, isHero: Bool = false, pager: HomeShelfPager?) {
        self.accessibilityLabel = title
        self.eyebrow = eyebrow
        self.pager = pager
        self.title = { HomeSectionTitleText(title: title, isHero: isHero) }
    }
}

// MARK: - HomeSectionTitleText

struct HomeSectionTitleText: View {
    let title: String
    var isHero = false

    var body: some View {
        Text(self.title)
            .font(self.isHero ? TuneTheme.Typeface.headline : TuneTheme.Typeface.section)
            .tracking(self.isHero ? -1 : -0.2)
    }
}
