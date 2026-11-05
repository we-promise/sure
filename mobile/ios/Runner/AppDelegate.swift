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
/// Keep the group lookup and generation handling in sync with SureWidgetStore
/// in the widget target.
enum WidgetBridge {
  private static let baseGroup = "group.am.sure.mobile"
  private static let configFile = "sure-widget-config.json"
  private static let snapshotFile = "sure-widget-snapshot.json"
  private static let generationFile = "sure-widget-generation.json"

  static func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "isAvailable":
      result(containerURL() != nil)

    case "update":
      guard let args = call.arguments as? [String: Any], let dir = containerURL() else {
        result(false)
        return
      }
      let generation = currentGeneration(in: dir)
      if var config = args["config"] as? [String: Any] {
        config["generation"] = generation
        write(config, to: dir.appendingPathComponent(configFile))
      }
      if var snapshot = args["snapshot"] as? [String: Any] {
        // Cached data only fills an empty widget; it never replaces newer data.
        let replaceExisting = args["replaceExisting"] as? Bool ?? true
        if replaceExisting || !hasSnapshot(in: dir, generation: generation) {
          snapshot["generation"] = generation
          write(snapshot, to: dir.appendingPathComponent(snapshotFile))
        }
      }
      WidgetCenter.shared.reloadAllTimelines()
      result(true)

    case "clear":
      if let dir = containerURL() {
        // Invalidate first, so a widget fetch already in progress can't save
        // the old account's data after the files are deleted.
        let next: [String: Any] = ["generation": currentGeneration(in: dir) + 1]
        write(next, to: dir.appendingPathComponent(generationFile))
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

  private static func readObject(at url: URL) -> [String: Any]? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
  }

  private static func currentGeneration(in dir: URL) -> Int {
    readObject(at: dir.appendingPathComponent(generationFile))?["generation"] as? Int ?? 0
  }

  private static func hasSnapshot(in dir: URL, generation: Int) -> Bool {
    guard let snapshot = readObject(at: dir.appendingPathComponent(snapshotFile)) else { return false }
    return (snapshot["generation"] as? Int ?? 0) == generation
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
