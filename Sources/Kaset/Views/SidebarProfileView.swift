// SidebarProfileView.swift
// Kaset
//
// Profile section displayed at the bottom of the sidebar for account management.

import SwiftUI

// MARK: - SidebarProfileView

/// A profile section displayed at the bottom of the sidebar.
///
/// Shows the current user's account info with an option to switch accounts
/// if brand accounts are available. C2: one compact row — a 20-point square avatar and the
/// account name — with no circles or icon badges.
struct SidebarProfileView: View {
    @Environment(AccountService.self) private var accountService
    @Environment(AuthService.self) private var authService

    @State private var showingAccountSwitcher = false

    var body: some View {
        Group {
            if self.authService.hasPersonalAccount {
                self.loggedInContent
            } else if self.authService.state.isLoggedIn {
                self.loggedInGuestContent
            } else {
                self.loggedOutContent
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Logged In Content

    @ViewBuilder
    private var loggedInContent: some View {
        if let account = accountService.currentAccount {
            Button {
                self.showingAccountSwitcher = true
            } label: {
                HStack(spacing: 10) {
                    self.avatarView(for: account)

                    Text(account.name)
                        .font(TuneTheme.Typeface.body)
                        .lineLimit(1)
                        .foregroundStyle(TuneTheme.Palette.inkSecondary)

                    Spacer(minLength: 0)

                    // Chevron indicator for account/guest switching.
                    if self.accountService.hasBrandAccounts || self.authService.state.isLoggedIn {
                        Image(systemName: "chevron.up.chevron.down")
                            .font(TuneTheme.Typeface.label)
                            .foregroundStyle(TuneTheme.Palette.inkDim)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(AccessibilityID.SidebarProfile.profileButton)
            .accessibilityLabel(self.profileAccessibilityLabel(for: account))
            .accessibilityHint(String(localized: "Double-tap to switch accounts or guest mode"))
            .popover(isPresented: self.$showingAccountSwitcher, arrowEdge: .top) {
                AccountSwitcherPopover()
                    .environment(self.authService)
                    .environment(self.accountService)
            }
        } else if self.accountService.isLoading {
            // Loading state only while account data is actively being fetched.
            // If auth is stale but there is no current account, show the guest
            // sign-in affordance instead of a permanent skeleton.
            self.loadingStateView
        } else if self.accountService.lastError != nil {
            // Error state - show retry option
            self.errorStateView
        } else {
            self.missingAccountContent
        }
    }

    private var missingAccountContent: some View {
        Button {
            Task {
                await self.accountService.fetchAccounts()
            }
        } label: {
            self.guestModeLabel(subtitle: String(localized: "Loading account…"))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(AccessibilityID.SidebarProfile.loadingState)
        .accessibilityLabel(String(localized: "Loading account"))
        .accessibilityHint(String(localized: "Double-tap to retry loading accounts"))
    }

    // MARK: - Loading State

    private var loadingStateView: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: TuneTheme.Radius.small, style: .continuous)
                .fill(TuneTheme.Palette.raised)
                .frame(width: Self.avatarSize, height: Self.avatarSize)

            RoundedRectangle(cornerRadius: TuneTheme.Radius.small / 2, style: .continuous)
                .fill(TuneTheme.Palette.raised)
                .frame(width: 80, height: 10)

            Spacer(minLength: 0)
        }
        .accessibilityIdentifier(AccessibilityID.SidebarProfile.loadingState)
    }

    // MARK: - Error State

    private var errorStateView: some View {
        HStack(spacing: 10) {
            Text(String(localized: "Failed to load"))
                .font(TuneTheme.Typeface.body)
                .foregroundStyle(TuneTheme.Palette.inkSecondary)
                .lineLimit(1)

            Text(String(localized: "Tap to retry"))
                .font(TuneTheme.Typeface.body)
                .foregroundStyle(TuneTheme.Palette.inkDim)
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            Task {
                self.accountService.clearError()
                await self.accountService.fetchAccounts()
            }
        }
        .accessibilityIdentifier(AccessibilityID.SidebarProfile.errorState)
        .accessibilityLabel(String(localized: "Failed to load accounts"))
        .accessibilityHint(String(localized: "Double-tap to retry"))
    }

    private var loggedInGuestContent: some View {
        Button {
            self.showingAccountSwitcher = true
        } label: {
            self.guestModeLabel(subtitle: String(localized: "Switch back to your account"))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(AccessibilityID.SidebarProfile.profileButton)
        .accessibilityLabel(String(localized: "Guest mode. Switch back to your account."))
        .popover(isPresented: self.$showingAccountSwitcher, arrowEdge: .top) {
            AccountSwitcherPopover()
                .environment(self.authService)
                .environment(self.accountService)
        }
    }

    // MARK: - Logged Out Content

    private var loggedOutContent: some View {
        Button {
            self.authService.startLogin()
        } label: {
            self.guestModeLabel(subtitle: String(localized: "Sign in for your library"))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(AccessibilityID.SidebarProfile.loggedOutState)
        .accessibilityLabel(String(localized: "Guest mode. Sign in for your library."))
    }

    private func guestModeLabel(subtitle: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "Guest Mode"))
                    .font(TuneTheme.Typeface.body)
                    .foregroundStyle(TuneTheme.Palette.inkSecondary)
                    .lineLimit(1)

                Text(subtitle)
                    .font(TuneTheme.Typeface.body)
                    .foregroundStyle(TuneTheme.Palette.inkDim)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    // MARK: - Avatar View

    @ViewBuilder
    private func avatarView(for account: UserAccount) -> some View {
        if let thumbnailURL = account.thumbnailURL {
            CachedAsyncImage(
                url: thumbnailURL,
                targetSize: CGSize(width: Self.avatarSize, height: Self.avatarSize)
            ) { image in
                image
                    .resizable()
                    .scaledToFill()
            } placeholder: {
                self.avatarPlaceholder
            }
            .frame(width: Self.avatarSize, height: Self.avatarSize)
            .clipShape(.rect(cornerRadius: TuneTheme.Radius.small, style: .continuous))
        } else {
            self.avatarPlaceholder
        }
    }

    private static let avatarSize: CGFloat = 20

    private var avatarPlaceholder: some View {
        RoundedRectangle(cornerRadius: TuneTheme.Radius.small, style: .continuous)
            .fill(TuneTheme.Palette.raised)
            .frame(width: Self.avatarSize, height: Self.avatarSize)
    }

    // MARK: - Accessibility

    private func profileAccessibilityLabel(for account: UserAccount) -> String {
        var label = "Profile: \(account.name)"
        if let handle = account.handle {
            label += ", \(handle)"
        }
        if self.accountService.hasBrandAccounts {
            label += ". Multiple accounts available."
        }
        return label
    }
}

// MARK: - AccessibilityID.SidebarProfile

extension AccessibilityID {
    enum SidebarProfile {
        static let container = "sidebarProfile"
        static let profileButton = "sidebarProfile.profileButton"
        static let loadingState = "sidebarProfile.loading"
        static let errorState = "sidebarProfile.error"
        static let loggedOutState = "sidebarProfile.loggedOut"
    }
}

// MARK: - Preview

#Preview("With Account") {
    let authService = AuthService()
    let ytMusicClient = YTMusicClient(authService: authService)
    let accountService = AccountService(ytMusicClient: ytMusicClient, authService: authService)

    SidebarProfileView()
        .environment(accountService)
        .environment(authService)
        .frame(width: 220)
        .padding()
}

#Preview("Logged Out") {
    let authService = AuthService()
    let ytMusicClient = YTMusicClient(authService: authService)
    let accountService = AccountService(ytMusicClient: ytMusicClient, authService: authService)

    SidebarProfileView()
        .environment(accountService)
        .environment(authService)
        .frame(width: 220)
        .padding()
}
