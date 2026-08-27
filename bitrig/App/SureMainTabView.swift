import SwiftUI

struct SureMainTabView: View {
  @Environment(SureStore.self) private var store

  var body: some View {
    @Bindable var store = store
    TabView(selection: $store.selectedTab) {
      SureOverviewView()
        .tabItem { Label("Overview", systemImage: "square.grid.2x2.fill") }
        .tag(SureTab.overview)

      SureAccountsView()
        .tabItem { Label("Accounts", systemImage: "building.columns.fill") }
        .tag(SureTab.accounts)

      SureBudgetsView()
        .tabItem { Label("Budgets", systemImage: "chart.pie.fill") }
        .tag(SureTab.budgets)

      SureAssistantView()
        .tabItem { Label("Assistant", systemImage: "sparkles") }
        .tag(SureTab.assistant)
    }
    .onReceive(NotificationCenter.default.publisher(for: .sureOpenInsights)) { _ in
      store.selectedTab = .overview
    }
  }
}
