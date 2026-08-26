import SwiftUI

struct SureBudgetsView: View {
  @Environment(SureStore.self) private var store

  var body: some View {
    NavigationStack {
      ScrollView {
        LazyVStack(spacing: 14) {
          ForEach(store.budgets) { budget in
            VStack(alignment: .leading, spacing: 12) {
              HStack {
                VStack(alignment: .leading, spacing: 3) {
                  Text(budget.name)
                    .font(.headline)
                  Text("\(budget.startDate) – \(budget.endDate)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                if budget.current {
                  Text("CURRENT")
                    .font(.caption2.bold())
                    .foregroundStyle(Color.sureMint)
                }
              }
              Divider()
              LabeledContent("Allocated", value: budget.allocatedSpending)
              if let planned = budget.budgetedSpending {
                LabeledContent("Planned", value: planned)
              }
            }
            .padding(18)
            .background(.background.secondary, in: .rect(cornerRadius: 18))
            .accessibilityElement(children: .combine)
          }
          if store.budgets.isEmpty && !store.isLoading {
            ContentUnavailableView(
              "No budgets yet",
              systemImage: "chart.pie",
              description: Text("Create a budget in Sure to track it here.")
            )
          }
        }
        .frame(maxWidth: .infinity)
        .padding()
      }
      .refreshable { await store.refreshAll() }
      .navigationTitle("Budgets")
    }
  }
}
