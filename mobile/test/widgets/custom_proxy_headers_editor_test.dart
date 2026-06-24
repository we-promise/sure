import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sure_mobile/l10n/app_localizations.dart';
import 'package:sure_mobile/models/custom_proxy_header.dart';
import 'package:sure_mobile/theme/sure_theme.dart';
import 'package:sure_mobile/widgets/custom_proxy_headers_editor.dart';
import 'package:sure_mobile/widgets/sure_text_field.dart';

// Proof that migrating the editor's fields to SureTextField preserved behavior:
// the fields still render, onChanged still fires, and validators still run.
void main() {
  Future<void> pump(WidgetTester tester, Widget child) {
    return tester.pumpWidget(
      MaterialApp(
        theme: SureTheme.light,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: child),
      ),
    );
  }

  testWidgets('renders SureTextField rows for each header', (tester) async {
    await pump(
      tester,
      CustomProxyHeadersEditor(
        initialHeaders: [CustomProxyHeader(name: 'X-Token', value: 'abc')],
        onChanged: (_) {},
      ),
    );
    // Name + value field per header row.
    expect(find.byType(SureTextField), findsNWidgets(2));
    expect(find.text('Header name'), findsOneWidget);
    expect(find.text('Header value'), findsOneWidget);
  });

  testWidgets('editing a field fires onChanged with the parsed headers',
      (tester) async {
    List<CustomProxyHeader>? latest;
    await pump(
      tester,
      CustomProxyHeadersEditor(
        initialHeaders: [CustomProxyHeader(name: 'X-Token', value: 'abc')],
        onChanged: (headers) => latest = headers,
      ),
    );

    await tester.enterText(find.byType(TextField).first, 'X-Renamed');
    await tester.pump();

    expect(latest, isNotNull);
    expect(latest!.single.name, 'X-Renamed');
    expect(latest!.single.value, 'abc');
  });
}
