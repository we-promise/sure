import SwiftUI
import UserNotifications

@main
struct SureApp: App {
  @UIApplicationDelegateAdaptor(SureAppDelegate.self) private var appDelegate
  @State private var store = SureStore()

  var body: some Scene {
    WindowGroup {
      SureRootView()
        .environment(store)
        .tint(Color.sureIndigo)
        .task {
          await store.restoreSession()
        }
        .onReceive(NotificationCenter.default.publisher(for: .sureDeviceTokenChanged)) { notification in
          guard let token = notification.object as? String else { return }
          Task { await store.registerPushToken(token) }
        }
    }
  }
}

final class SureAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    UNUserNotificationCenter.current().delegate = self
    Task {
      let settings = await UNUserNotificationCenter.current().notificationSettings()
      if settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional {
        await MainActor.run { application.registerForRemoteNotifications() }
      }
    }
    return true
  }

  func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    let token = deviceToken.map { String(format: "%02x", $0) }.joined()
    UserDefaults.standard.set(token, forKey: "sure.apnsDeviceToken")
    NotificationCenter.default.post(name: .sureDeviceTokenChanged, object: token)
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .sound, .badge])
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    NotificationCenter.default.post(name: .sureOpenInsights, object: nil)
    completionHandler()
  }
}

extension Notification.Name {
  static var sureDeviceTokenChanged: Notification.Name { Notification.Name("sureDeviceTokenChanged") }
  static var sureOpenInsights: Notification.Name { Notification.Name("sureOpenInsights") }
}

extension Color {
  static var sureIndigo: Color { Color(red: 0.29, green: 0.25, blue: 0.85) }
  static var sureMint: Color { Color(red: 0.22, green: 0.73, blue: 0.58) }
}
