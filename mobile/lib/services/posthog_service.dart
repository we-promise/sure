import 'package:posthog_flutter/posthog_flutter.dart';
import 'log_service.dart';

class PosthogService {
  // Same values used by the progressive web app (POSTHOG_KEY / POSTHOG_HOST).
  // These are public, client-side analytics keys — not secrets.
  static const String apiKey = 'phc_NnFhGFnKOaUpp0bG1mHfcUEsVg7KDXO8xMBMBguBbCP';
  static const String host = 'https://us.i.posthog.com';

  static bool _initialized = false;
  static bool get isInitialized => _initialized;

  /// Initialise PostHog with session replay enabled.
  /// Call once in `main()` before `runApp()`.
  static Future<void> initialize() async {
    if (apiKey.isEmpty) {
      LogService.instance.info('PostHog', 'No API key configured – skipping init');
      return;
    }

    try {
      final config = PostHogConfig(apiKey);
      config.host = host;
      config.captureApplicationLifecycleEvents = true;
      config.debug = false;
      config.sessionReplay = true;
      config.sessionReplayConfig.maskAllTexts = true;
      config.sessionReplayConfig.maskAllImages = true;

      await Posthog().setup(config);
      _initialized = true;
      LogService.instance.info('PostHog', 'Initialized with session replay');
    } catch (e) {
      LogService.instance.error('PostHog', 'Failed to initialize: $e');
    }
  }
}
