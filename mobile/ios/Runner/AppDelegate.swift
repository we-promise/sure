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
      // The widget extension needs iOS 17.
      if #available(iOS 17.0, *) {
        result(containerURL() != nil)
      } else {
        result(false)
      }

    case "update":
      guard let args = call.arguments as? [String: Any], let dir = containerURL() else {
        result(false)
        return
      }
      let generation = currentGeneration(in: dir)
      let snapshotURL = dir.appendingPathComponent(snapshotFile)
      var ok = true
      if var config = args["config"] as? [String: Any] {
        // Balances saved under another key or server belong to that login, so
        // drop them instead of showing them as current.
        if let old = readObject(at: dir.appendingPathComponent(configFile)),
           (old["generation"] as? Int ?? 0) == generation,
           old["apiKey"] as? String != config["apiKey"] as? String
            || old["baseUrl"] as? String != config["baseUrl"] as? String {
          try? FileManager.default.removeItem(at: snapshotURL)
        }
        config["generation"] = generation
        ok = write(config, to: dir.appendingPathComponent(configFile)) && ok
      }
      if var snapshot = args["snapshot"] as? [String: Any] {
        // Cached data only fills an empty widget; it never replaces newer data.
        let replaceExisting = args["replaceExisting"] as? Bool ?? true
        if replaceExisting || !hasSnapshot(in: dir, generation: generation) {
          snapshot["generation"] = generation
          ok = write(snapshot, to: snapshotURL) && ok
        } else if let netWorth = snapshot["netWorth"] as? String,
                  var existing = readObject(at: snapshotURL) {
          // Keep the saved accounts but take the newer net worth.
          existing["netWorth"] = netWorth
          ok = write(existing, to: snapshotURL) && ok
        }
      }
      WidgetCenter.shared.reloadAllTimelines()
      result(ok)

    case "clear":
      guard let dir = containerURL() else {
        result(true)  // No shared storage, so nothing to clear.
        return
      }
      // Invalidate first, so a widget fetch already in progress can't save
      // the old account's data after the files are deleted. If that fails,
      // report it: the files are still deleted, but the caller retries.
      let next: [String: Any] = ["generation": currentGeneration(in: dir) + 1]
      let invalidated = write(next, to: dir.appendingPathComponent(generationFile))
      for name in [configFile, snapshotFile] {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
      }
      WidgetCenter.shared.reloadAllTimelines()
      result(invalidated)

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

  @discardableResult
  private static func write(_ object: Any, to url: URL) -> Bool {
    guard JSONSerialization.isValidJSONObject(object),
          let data = try? JSONSerialization.data(withJSONObject: object) else { return false }
    do {
      try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
      return true
    } catch {
      return false
    }
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
