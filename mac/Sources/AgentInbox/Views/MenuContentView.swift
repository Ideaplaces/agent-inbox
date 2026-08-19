import AppKit
import SwiftUI

@MainActor
struct MenuContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if !model.settings.isConfigured {
                setupPrompt
            } else if model.store.unread.isEmpty {
                emptyState
            } else {
                itemList
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
        .frame(width: 420)
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
            switch model.poller.status {
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

    private var itemList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(model.store.unread.reversed()) { item in
                    ItemRow(item: item)
                    Divider().padding(.leading, 40)
                }
            }
        }
        .frame(maxHeight: 420)
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
            Button("Mark All Read") { model.store.markAllRead() }
                .disabled(!model.store.hasUnread)
            if model.settings.historyURL != nil {
                Button("History") { model.openHistory() }
            }
            Spacer()
            SettingsLink {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
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

            VStack(alignment: .leading, spacing: 2) {
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
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 4)
                    Text(item.receivedAt, style: .time)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let waiting = item.waitingOn {
                    Text(waiting)
                        .font(.system(size: 11))
                        .foregroundStyle(.primary.opacity(0.75))
                        .lineLimit(2)
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
        .padding(.vertical, 8)
        .background(isHovered ? Color.primary.opacity(0.06) : .clear)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture { model.open(item) }
        .help(item.cwd.map { "Open \($0)" } ?? "")
    }
}
