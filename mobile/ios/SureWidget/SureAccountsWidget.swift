import AppIntents
import SwiftUI
import WidgetKit

// MARK: - Timeline

struct AccountsEntry: TimelineEntry {
    let date: Date
    let snapshot: SureWidgetSnapshot?
    let isLive: Bool
    let needsSetup: Bool
    let configuration: AccountsWidgetIntent

    static func placeholder(_ configuration: AccountsWidgetIntent = AccountsWidgetIntent()) -> AccountsEntry {
        AccountsEntry(
            date: Date(),
            snapshot: SureWidgetSnapshot(updatedAt: Date(), accounts: [
                SureWidgetAccount(id: "1", name: "Checking", balance: "$2,450.12", balanceCents: 245012,
                                  currency: "USD", classification: "asset", accountType: "depository",
                                  institutionName: "Credit Union"),
                SureWidgetAccount(id: "2", name: "Savings", balance: "$8,100.00", balanceCents: 810000,
                                  currency: "USD", classification: "asset", accountType: "depository",
                                  institutionName: "Credit Union"),
                SureWidgetAccount(id: "3", name: "Roth IRA", balance: "$15,320.44", balanceCents: 1532044,
                                  currency: "USD", classification: "asset", accountType: "investment",
                                  institutionName: "Brokerage"),
            ]),
            isLive: true,
            needsSetup: false,
            configuration: configuration
        )
    }
}

struct AccountsProvider: AppIntentTimelineProvider {
    /// A snapshot newer than this is reused instead of fetching again (e.g. right
    /// after the refresh button already fetched).
    private let reuseWindow: TimeInterval = 60

    func placeholder(in context: Context) -> AccountsEntry { .placeholder() }

    func snapshot(for configuration: AccountsWidgetIntent, in context: Context) async -> AccountsEntry {
        if context.isPreview, SureWidgetStore.loadSnapshot() == nil {
            return .placeholder(configuration)
        }
        return await makeEntry(configuration)
    }

    func timeline(for configuration: AccountsWidgetIntent, in context: Context) async -> Timeline<AccountsEntry> {
        let entry = await makeEntry(configuration)
        // iOS treats this as a request; it may refresh less often on low battery
        // or when the widget is rarely seen.
        let next = Date().addingTimeInterval(15 * 60)
        return Timeline(entries: [entry], policy: .after(next))
    }

    private func makeEntry(_ configuration: AccountsWidgetIntent) async -> AccountsEntry {
        if let saved = SureWidgetStore.loadSnapshot(),
           Date().timeIntervalSince(saved.updatedAt) < reuseWindow {
            return AccountsEntry(date: Date(), snapshot: saved, isLive: true, needsSetup: false,
                                 configuration: configuration)
        }
        let result = await SureWidgetAPI.refreshSnapshot()
        return AccountsEntry(date: Date(), snapshot: result.snapshot, isLive: result.isLive,
                             needsSetup: result.needsSetup, configuration: configuration)
    }
}

// MARK: - Helpers

extension AccountsEntry {
    var accounts: [SureWidgetAccount] {
        let all = snapshot?.accounts ?? []
        let visible = configuration.showLiabilities ? all : all.filter { !$0.isLiability }
        // Assets first, then liabilities; largest balances first within each.
        return visible.sorted { a, b in
            if a.isLiability != b.isLiability { return !a.isLiability }
            return abs(a.balanceCents ?? 0) > abs(b.balanceCents ?? 0)
        }
    }

    /// Net worth as computed by the server (in the family's currency), if loaded.
    var netWorth: String? {
        guard configuration.showNetWorth else { return nil }
        return snapshot?.netWorth
    }
}

// MARK: - Views

struct AccountsWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: AccountsEntry

    var body: some View {
        Group {
            if entry.snapshot == nil {
                EmptyStateView(needsSetup: entry.needsSetup, compact: family == .accessoryRectangular)
            } else {
                switch family {
                case .accessoryRectangular: LockScreenView(entry: entry)
                case .systemSmall: ListLayout(entry: entry, maxRows: 3, compact: true)
                case .systemMedium: ListLayout(entry: entry, maxRows: 4, compact: false)
                default: ListLayout(entry: entry, maxRows: 12, compact: false)
                }
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

private struct ListLayout: View {
    let entry: AccountsEntry
    let maxRows: Int
    let compact: Bool

    var body: some View {
        let accounts = entry.accounts
        let shown = Array(accounts.prefix(maxRows))
        let hidden = accounts.count - shown.count

        VStack(alignment: .leading, spacing: compact ? 4 : 6) {
            Header(entry: entry, compact: compact)

            // Rows take whatever space is left and are clipped, so the header
            // and footer always stay visible even with large text sizes.
            VStack(alignment: .leading, spacing: compact ? 4 : 5) {
                ForEach(shown) { account in
                    AccountRow(account: account, compact: compact)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipped()

            HStack(spacing: 4) {
                if hidden > 0 {
                    Text("+\(hidden) more")
                }
                Spacer(minLength: 0)
                if entry.needsSetup {
                    // No API key: showing saved balances, auto-refresh is off.
                    Image(systemName: "key")
                } else if !entry.isLive {
                    Image(systemName: "wifi.slash")
                }
                if let updated = entry.snapshot?.updatedAt {
                    Text(updated, style: .time)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }
}

private struct Header: View {
    let entry: AccountsEntry
    let compact: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let netWorth = entry.netWorth, !compact {
                Text(netWorth)
                    .font(.headline)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .privacySensitive()
                Text("net worth")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text("Accounts")
                    .font(compact ? .caption.weight(.semibold) : .headline)
            }
            Spacer(minLength: 0)
            Button(intent: RefreshAccountsIntent()) {
                Image(systemName: "arrow.clockwise")
                    .font(compact ? .caption : .footnote)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }
}

private struct AccountRow: View {
    let account: SureWidgetAccount
    let compact: Bool

    var body: some View {
        if compact {
            VStack(alignment: .leading, spacing: 0) {
                Text(account.name)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .privacySensitive()
                balanceText.font(.subheadline.weight(.semibold))
            }
        } else {
            HStack(alignment: .firstTextBaseline) {
                Text(account.name)
                    .font(.footnote)
                    .lineLimit(1)
                    .privacySensitive()
                Spacer(minLength: 8)
                balanceText.font(.footnote.weight(.semibold))
            }
        }
    }

    private var balanceText: some View {
        Text(account.balance)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .foregroundStyle(account.isLiability ? Color.red : Color.primary)
            .privacySensitive()
    }
}

private struct LockScreenView: View {
    let entry: AccountsEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(entry.accounts.prefix(3))) { account in
                HStack {
                    Text(account.name)
                        .lineLimit(1)
                        .privacySensitive()
                    Spacer(minLength: 4)
                    Text(account.balance)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .privacySensitive()
                }
                .font(.caption)
            }
        }
    }
}

private struct EmptyStateView: View {
    let needsSetup: Bool
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !compact {
                Image(systemName: "creditcard")
                    .font(.title3)
            }
            Text(needsSetup ? "Open Sure, then More → Home Screen Widget" : "Couldn't reach your Sure server")
                .font(.caption)
            if !needsSetup && !compact {
                Button(intent: RefreshAccountsIntent()) {
                    Label("Retry", systemImage: "arrow.clockwise").font(.caption)
                }
            }
        }
    }
}

// MARK: - Widget

struct SureAccountsWidget: Widget {
    let kind = "SureAccountsWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: AccountsWidgetIntent.self, provider: AccountsProvider()) { entry in
            AccountsWidgetView(entry: entry)
        }
        .configurationDisplayName("Account Balances")
        .description("Your Sure account balances, refreshed automatically or with the refresh button.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular])
    }
}

@main
struct SureWidgetBundle: WidgetBundle {
    var body: some Widget {
        SureAccountsWidget()
    }
}
