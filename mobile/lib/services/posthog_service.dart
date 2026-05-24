import 'package:posthog_flutter/posthog_flutter.dart';

import 'log_service.dart';

class PostHogService {
  PostHogService._();

  static const String _apiKey = String.fromEnvironment('POSTHOG_API_KEY');
  static const String _host = String.fromEnvironment(
    'POSTHOG_HOST',
    defaultValue: 'https://us.i.posthog.com',
  );

  static Future<void> initialize() async {
    if (_apiKey.isEmpty) {
      LogService.instance.info(
        'PostHog',
        'PostHog disabled: POSTHOG_API_KEY is not configured.',
      );
      return;
    }

    final config = PostHogConfig(_apiKey, host: _host);
    config.sessionReplay = true;

    await Posthog().setup(config);

    LogService.instance.info(
      'PostHog',
      'PostHog initialized with session replay enabled.',
    );
  }
}
