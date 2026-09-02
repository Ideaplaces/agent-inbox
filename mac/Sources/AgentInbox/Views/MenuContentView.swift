import AppKit
import SwiftUI

/// Reports the measured height of the row stack.
private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

@MainActor
struct MenuContentView: View {
    @Environment(AppModel.self) private var model
    @State private var contentHeight: CGFloat = 0
    @State private var settingsContentHeight: CGFloat = 0

    /// One row is roughly 56pt, so this keeps a single item visible even
    /// before the first measurement lands.
    static let minimumListHeight: CGFloat = 56
    static let maximumListHeight: CGFloat = 640

    /// The height to give the list for a measured content height.
    ///
    /// Separated out so the property that actually broke can be asserted: this
    /// must never return zero. A zero here is invisible, because the badge goes
    /// on counting items that the menu is no longer drawing.
    static func listHeight(forContent measured: CGFloat) -> CGFloat {
        min(max(measured, minimumListHeight), maximumListHeight)
    }

    /// The height to give the settings page. Its floor is higher than the
    /// list's: one row of settings is not a useful page, and a settings screen
    /// that opens two controls tall reads as broken rather than as short.
    static let minimumSettingsHeight: CGFloat = 260

    static func settingsHeight(forContent measured: CGFloat) -> CGFloat {
        min(max(measured, minimumSettingsHeight), maximumListHeight)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch model.menuRoute {
            case .inbox:
                header
                Divider()

                if !model.settings.isConfigured {
                    setupPrompt
                } else if model.store.unread.isEmpty {
                    emptyState
                } else {
                    itemList
                }
            case .settings:
                settingsHeader
                Divider()
                settingsBody
            }

            if let message = model.transientMessage {
                Divider()
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            footer
        }
        .frame(width: 560)
    }

    /// The settings page's own header: a way back, and a title saying where
    /// you are. Both matter, because the popover has no window chrome to tell
    /// you either.
    private var settingsHeader: some View {
        HStack(spacing: 8) {
            Button {
                model.menuRoute = .inbox
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .help("Back to the inbox")
            Text("Settings")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// Measured and clamped exactly like the list, and for the same reason: a
    /// ScrollView has no height of its own, and inside a popover that sizes
    /// itself to its content nothing establishes a floor, so it can be handed
    /// zero and simply not draw.
    private var settingsBody: some View {
        ScrollView {
            SettingsPanes()
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: ContentHeightKey.self, value: proxy.size.height)
                    }
                )
        }
        .frame(height: Self.settingsHeight(forContent: settingsContentHeight))
        .onPreferenceChange(ContentHeightKey.self) { settingsContentHeight = $0 }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Agent Inbox")
                .font(.system(size: 13, weight: .semibold))
            statusDot
            Spacer()
            if model.store.needsYouCount > 0 {
                countChip(
                    ItemKind.needsYou.symbol, model.store.needsYouCount, tint: .orange)
            }
            if model.store.finishedCount > 0 {
                countChip(
                    ItemKind.finished.symbol, model.store.finishedCount, tint: .green)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var statusDot: some View {
        let (color, help): (Color, String) = {
            switch model.receiver.status {
            case .connected: return (.green, "Connected")
            case .connecting: return (.yellow, "Connecting")
            case .notConfigured: return (.secondary, "No transport configured")
            case .failed(let reason): return (.red, reason)
            }
        }()
        return Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .help(help)
    }

    private func countChip(_ symbol: String, _ count: Int, tint: Color) -> some View {
        Text("\(symbol) \(count)")
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(tint.opacity(0.15), in: Capsule())
    }

    /// The rows, in a scroll view whose height is measured rather than proposed.
    ///
    /// A ScrollView has no intrinsic height. Inside a menubar popover, which
    /// sizes itself to its content, `.frame(maxHeight:)` is only a ceiling and
    /// nothing establishes a floor, so the whole list can be handed zero height
    /// and vanish while the badge still counts the items. That is exactly what
    /// happened when the cap went from 420 to 640: header and footer drew, and
    /// the rows between them were silently given no room.
    ///
    /// Measuring the content and clamping to it gives the popover a definite
    /// height to work with. VStack rather than LazyVStack because a lazy stack
    /// only measures the rows it has materialised, which is none of them when
    /// the height is still zero.
    private var itemList: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(model.store.unread.reversed()) { item in
                    ItemRow(item: item)
                    Divider().padding(.leading, 40)
                }
            }
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: ContentHeightKey.self, value: proxy.size.height)
                }
            )
        }
        .frame(height: Self.listHeight(forContent: contentHeight))
        .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
    }

    private var emptyState: some View {
        VStack(spacing: 4) {
            Image(systemName: "tray")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Nothing waiting")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text("Sessions appear here when they finish or need you.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    private var setupPrompt: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Not set up yet")
                .font(.system(size: 12, weight: .semibold))
            Text("Pick a transport and Agent Inbox starts listening to every Claude Code session, here and on your other machines.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Set Up Agent Inbox") {
                WelcomeWindowController.shared.show()
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if model.menuRoute == .inbox {
                Button("Mark All Read") { model.store.markAllRead() }
                    .disabled(!model.store.hasUnread)
                if model.settings.historyURL != nil {
                    Button("History") { model.openHistory() }
                }
            }
            Spacer()
            Button("Check for Updates") { model.updater.checkForUpdates() }
                .disabled(!model.updater.canCheck)
            if model.menuRoute == .inbox {
                Button {
                    model.menuRoute = .settings
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .help("Settings")
            }
            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.borderless)
            .help("Quit Agent Inbox")
        }
        .buttonStyle(.link)
        .font(.system(size: 11))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

@MainActor
private struct ItemRow: View {
    @Environment(AppModel.self) private var model
    let item: InboxItem
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.kind.icon)
                .foregroundStyle(item.kind == .needsYou ? Color.orange : Color.green)
                .font(.system(size: 13))
                .frame(width: 18)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.repo)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Text("@ \(item.host)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let duration = item.duration {
                        Text(duration)
                            .note(.tertiary)
                    }
                    Spacer(minLength: 4)
                    Text(item.receivedAt, style: .time)
                        .note(.tertiary)
                }
                if let thread = item.thread {
                    Text(thread)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if let subtitle = item.subtitle {
                    Text(MarkdownText.attributed(subtitle))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let closing = item.closingWords {
                    Text(MarkdownText.attributed(closing))
                        .font(.system(size: 12))
                        .foregroundStyle(.primary.opacity(0.75))
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if item.isShortTurn {
                    HStack(spacing: 4) {
                        Text("A \(item.elapsed ?? 0)s turn. Turns this short can be hidden in")
                            .note(.tertiary)
                        // Styled on its own, or it inherits the note's grey and
                        // stops looking like something you can click.
                        Button("Settings") { model.menuRoute = .settings }
                            .buttonStyle(.link)
                            .font(.system(size: 10))
                    }
                }
                if let waiting = item.waitingOn {
                    Text(MarkdownText.attributed(waiting))
                        .font(.system(size: 12))
                        .foregroundStyle(.primary.opacity(0.75))
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Button {
                model.store.markRead(item.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .opacity(isHovered ? 1 : 0)
            .help("Mark read")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(isHovered ? Color.primary.opacity(0.06) : .clear)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture { model.store.markRead(item.id) }
        .help(item.cwd ?? "")
    }
}
