import SwiftUI

struct SureSetupView: View {
  @Environment(SureStore.self) private var store
  @State private var server = "https://demo.sure.am"
  @State private var apiKey = ""
  @FocusState private var focusedField: SetupField?

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "circle.hexagongrid.fill")
              .font(.system(size: 52))
              .foregroundStyle(.tint)
              .accessibilityHidden(true)
            Text("Your finances, made clear")
              .font(.largeTitle.bold())
            Text("Connect securely to Sure with an API key. Your key stays in this device’s Keychain.")
              .font(.title3)
              .foregroundStyle(.secondary)
          }

          VStack(spacing: 16) {
            TextField("Sure server", text: $server)
              .textContentType(.URL)
              .keyboardType(.URL)
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled()
              .focused($focusedField, equals: .server)
              .accessibilityLabel("Sure server address")
            SecureField("Read/write API key", text: $apiKey)
              .textContentType(.password)
              .focused($focusedField, equals: .apiKey)
              .accessibilityLabel("Sure read/write API key")
          }
          .padding(18)
          .background(.background.secondary, in: .rect(cornerRadius: 20))

          VStack(alignment: .leading, spacing: 10) {
            Label("Connect to the demo", systemImage: "person.badge.key.fill")
              .font(.headline)
            Text("Sign in through the Sure demo, then create a read/write key in Settings → API keys. Paste that key above.")
              .font(.subheadline)
              .foregroundStyle(.secondary)
            Link("Open Sure demo", destination: URL(string: "https://demo.sure.am")!)
              .font(.subheadline.weight(.semibold))
          }
          .padding(16)
          .background(Color.sureIndigo.opacity(0.09), in: .rect(cornerRadius: 16))

          if let errorMessage = store.errorMessage {
            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
              .font(.subheadline)
              .foregroundStyle(.red)
              .accessibilityAddTraits(.isStaticText)
          }

          Button {
            focusedField = nil
            Task { await store.connect(baseURL: server, apiKey: apiKey) }
          } label: {
            HStack {
              if store.isLoading {
                ProgressView()
                  .tint(.white)
              }
              Text(store.isLoading ? "Connecting…" : "Connect to Sure")
                .fontWeight(.semibold)
              Spacer()
              Image(systemName: "arrow.right")
            }
            .foregroundStyle(.white)
            .padding()
            .background(Color.sureIndigo, in: .rect(cornerRadius: 16))
          }
          .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isLoading)
        }
        .frame(maxWidth: 620, alignment: .leading)
        .padding(24)
      }
      .navigationTitle("Sure")
    }
  }
}

private enum SetupField {
  case server
  case apiKey
}
