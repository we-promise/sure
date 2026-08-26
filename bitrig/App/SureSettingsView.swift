import SwiftUI
import UserNotifications

struct SureSettingsView: View {
  @Environment(SureStore.self) private var store
  @Environment(\.dismiss) private var dismiss
  @AppStorage("sure.insightNotifications") private var insightNotifications = false
  @State private var notificationStatus = ""

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          VStack(alignment: .leading, spacing: 8) {
            Text("Connection")
              .font(.headline)
            Label(store.baseURLString, systemImage: "lock.fill")
              .font(.subheadline)
              .foregroundStyle(.secondary)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(18)
          .background(.background.secondary, in: .rect(cornerRadius: 18))

          VStack(alignment: .leading, spacing: 12) {
            Toggle("AI insight notifications", systemImage: "bell.badge.fill", isOn: $insightNotifications)
              .onChange(of: insightNotifications) {
                Task { await updateNotificationPreference() }
              }
            Text("Get notified when Sure finds a new proactive financial insight. You stay in control in iOS Settings.")
              .font(.subheadline)
              .foregroundStyle(.secondary)
            if !notificationStatus.isEmpty {
              Text(notificationStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
          .padding(18)
          .background(.background.secondary, in: .rect(cornerRadius: 18))

          Button(role: .destructive) {
            Task {
              await store.disconnect()
              dismiss()
            }
          } label: {
            Label("Disconnect this device", systemImage: "rectangle.portrait.and.arrow.right")
              .frame(maxWidth: .infinity)
              .padding(14)
              .background(Color.red.opacity(0.09), in: .rect(cornerRadius: 14))
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
      }
      .navigationTitle("Settings")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
      .task { await readNotificationStatus() }
    }
  }

  private func updateNotificationPreference() async {
    if insightNotifications {
      do {
        let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        insightNotifications = granted
        if granted {
          await MainActor.run { UIApplication.shared.registerForRemoteNotifications() }
          notificationStatus = "Notifications are enabled."
        } else {
          notificationStatus = "Notifications are off in iOS Settings."
        }
      } catch {
        insightNotifications = false
        notificationStatus = error.localizedDescription
      }
    } else {
      await store.unregisterPushToken()
      notificationStatus = "Notifications are disabled for this device."
    }
  }

  private func readNotificationStatus() async {
    let settings = await UNUserNotificationCenter.current().notificationSettings()
    if settings.authorizationStatus == .denied {
      insightNotifications = false
      notificationStatus = "Notifications are off in iOS Settings."
    }
  }
}
