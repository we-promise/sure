import 'package:flutter_test/flutter_test.dart';
import 'package:sure_mobile/services/widget_bridge_service.dart';

void main() {
  group('WidgetBridgeService.iosMajorVersion', () {
    test('reads the major version from iOS version strings', () {
      expect(WidgetBridgeService.iosMajorVersion('Version 17.4.1 (Build 21E236)'), 17);
      expect(WidgetBridgeService.iosMajorVersion('16.7.8'), 16);
      expect(WidgetBridgeService.iosMajorVersion('Version 26.0 (Build 23A341)'), 26);
    });

    test('returns 0 when there is no version number', () {
      expect(WidgetBridgeService.iosMajorVersion(''), 0);
      expect(WidgetBridgeService.iosMajorVersion('unknown'), 0);
    });
  });

  group('WidgetBridgeService.widgetAllowsServer', () {
    test('allows any HTTPS server', () {
      expect(WidgetBridgeService.widgetAllowsServer('https://sure.example.com'), isTrue);
    });

    test('allows plain HTTP only where App Transport Security does', () {
      expect(WidgetBridgeService.widgetAllowsServer('http://192.168.1.20:3000'), isTrue);
      expect(WidgetBridgeService.widgetAllowsServer('http://sure.local'), isTrue);
      expect(WidgetBridgeService.widgetAllowsServer('http://myserver'), isTrue);
      expect(WidgetBridgeService.widgetAllowsServer('http://sure.example.com'), isFalse);
    });
  });
}
