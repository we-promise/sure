import SwiftUI

struct SureOverviewView: View {
  @Environment(SureStore.self) private var store
  @State private var showingSettings = false

  var body: some View {
    NavigationStack {
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 22) {
          if !store.insights.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
              HStack {
                Label("AI insights", systemImage: "sparkles")
                  .font(.title2.bold())
                Spacer()
                Text("LIVE")
                  .font(.caption2.bold())
                  .foregroundStyle(Color.sureMint)
                  .padding(.horizontal, 8)
                  .padding(.vertical, 4)
                  .background(Color.sureMint.opacity(0.12), in: .capsule)
              }
              Text("Proactive signals from your latest Sure data")
                .font(.subheadline)
                .foregroundStyle(.secondary)

              ForEach(store.insights) { insight in
                SureInsightCard(insight: insight)
              }
            }
          }

          if let balance = store.balanceSheet {
            VStack(alignment: .leading, spacing: 18) {
              Text("Net worth")
                .font(.headline)
                .foregroundStyle(.secondary)
              Text(balance.netWorth.formatted)
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .contentTransition(.numericText())

              HStack(spacing: 12) {
                SureMetricCard(title: "Assets", value: balance.assets.formatted, color: Color.sureMint)
                SureMetricCard(title: "Liabilities", value: balance.liabilities.formatted, color: .orange)
              }
            }
            .padding(20)
            .background(.background.secondary, in: .rect(cornerRadius: 22))
          }

          VStack(alignment: .leading, spacing: 12) {
            HStack {
              Text("Accounts")
                .font(.title2.bold())
              Spacer()
              Button("See all") { store.selectedTab = .accounts }
            }
            ForEach(store.accounts.prefix(4)) { account in
              SureAccountRow(account: account)
            }
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
      }
      .refreshable { await store.refreshAll() }
      .navigationTitle("Overview")
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button("Settings", systemImage: "gearshape") { showingSettings = true }
            .labelStyle(.iconOnly)
        }
      }
      .sheet(isPresented: $showingSettings) {
        SureSettingsView()
      }
      .overlay {
        if store.isLoading && store.balanceSheet == nil {
          ProgressView("Loading your finances…")
        }
      }
    }
  }
}

struct SureInsightCard: View {
  var insight: SureInsight

  var body: some View {
    HStack(alignment: .top, spacing: 14) {
      Image(systemName: insight.symbol)
        .font(.title3)
        .foregroundStyle(insight.priority == "high" ? Color.orange : Color.sureIndigo)
        .frame(width: 36, height: 36)
        .background(
          (insight.priority == "high" ? Color.orange : Color.sureIndigo).opacity(0.12),
          in: .circle
        )
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 5) {
        Text(insight.title)
          .font(.headline)
        Text(insight.body)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(16)
    .background(Color.sureIndigo.opacity(0.055), in: .rect(cornerRadius: 18))
    .accessibilityElement(children: .combine)
  }
}

struct SureMetricCard: View {
  var title: String
  var value: String
  var color: Color

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title)
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(value)
        .font(.headline)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(14)
    .background(color.opacity(0.1), in: .rect(cornerRadius: 14))
    .accessibilityElement(children: .combine)
  }
}
