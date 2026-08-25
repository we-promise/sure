import SwiftUI

struct SureAccountsView: View {
  @Environment(SureStore.self) private var store

  var body: some View {
    NavigationStack {
      ScrollView {
        LazyVStack(spacing: 12) {
          ForEach(store.accounts) { account in
            SureAccountRow(account: account)
              .padding(.horizontal)
          }
          if store.accounts.isEmpty && !store.isLoading {
            ContentUnavailableView(
              "No accounts",
              systemImage: "building.columns",
              description: Text("Add or link an account in Sure, then pull to refresh.")
            )
          }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical)
      }
      .refreshable { await store.refreshAll() }
      .navigationTitle("Accounts")
    }
  }
}

struct SureAccountRow: View {
  var account: SureAccount

  var body: some View {
    HStack(spacing: 14) {
      Image(systemName: symbol)
        .font(.title3)
        .foregroundStyle(.tint)
        .frame(width: 42, height: 42)
        .background(Color.sureIndigo.opacity(0.1), in: .circle)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 3) {
        Text(account.name)
          .font(.headline)
        Text(account.institutionName ?? accountTypeLabel)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      Text(account.balance)
        .font(.headline.monospacedDigit())
    }
    .padding(14)
    .background(.background.secondary, in: .rect(cornerRadius: 16))
    .accessibilityElement(children: .combine)
  }

  private var symbol: String {
    switch account.accountType {
    case "investment": "chart.line.uptrend.xyaxis"
    case "credit_card": "creditcard.fill"
    case "property": "house.fill"
    case "vehicle": "car.fill"
    case "loan": "doc.text.fill"
    default: account.isAsset ? "banknote.fill" : "arrow.down.right"
    }
  }

  private var accountTypeLabel: String {
    (account.subtype ?? account.accountType ?? account.classification)
      .replacingOccurrences(of: "_", with: " ")
      .capitalized
  }
}
