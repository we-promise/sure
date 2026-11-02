import UIKit
import Flutter
import WidgetKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    if let registrar = registrar(forPlugin: "SureWidgetBridge") {
      let channel = FlutterMethodChannel(
        name: "am.sure.mobile/widget",
        binaryMessenger: registrar.messenger()
      )
      channel.setMethodCallHandler { call, result in
        WidgetBridge.handle(call, result: result)
      }
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}

/// Writes the files the home screen widget reads from the shared App Group.
/// Keep the group lookup in sync with SureWidgetStore in the widget target.
enum WidgetBridge {
  private static let baseGroup = "group.am.sure.mobile"
  private static let configFile = "sure-widget-config.json"
  private static let snapshotFile = "sure-widget-snapshot.json"

  static func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "isAvailable":
      result(containerURL() != nil)

    case "update":
      guard let args = call.arguments as? [String: Any], let dir = containerURL() else {
        result(false)
        return
      }
      if let config = args["config"] {
        write(config, to: dir.appendingPathComponent(configFile))
      }
      if let snapshot = args["snapshot"] {
        write(snapshot, to: dir.appendingPathComponent(snapshotFile))
      }
      WidgetCenter.shared.reloadAllTimelines()
      result(true)

    case "clear":
      if let dir = containerURL() {
        for name in [configFile, snapshotFile] {
          try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
      }
      WidgetCenter.shared.reloadAllTimelines()
      result(true)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private static func write(_ object: Any, to url: URL) {
    guard JSONSerialization.isValidJSONObject(object),
          let data = try? JSONSerialization.data(withJSONObject: object) else { return }
    try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
  }

  /// Re-signing tools such as AltStore and SideStore rename the App Group and
  /// record the new name under `ALTAppGroups`.
  static func containerURL() -> URL? {
    let info = Bundle.main.infoDictionary ?? [:]
    var groups = (info["ALTAppGroups"] as? [String]) ?? []
    if let configured = info["SureAppGroup"] as? String { groups.append(configured) }
    groups.append(baseGroup)

    for group in groups {
      if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) {
        return url
      }
    }
    return nil
  }
}
