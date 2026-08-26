import SwiftUI

struct SureRootView: View {
  @Environment(SureStore.self) private var store

  var body: some View {
    Group {
      if store.isConfigured {
        SureMainTabView()
      } else {
        SureSetupView()
      }
    }
    .animation(.smooth, value: store.isConfigured)
  }
}
