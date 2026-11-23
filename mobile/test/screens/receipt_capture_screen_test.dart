import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sure_mobile/l10n/app_localizations.dart';
import 'package:sure_mobile/models/account.dart';
import 'package:sure_mobile/providers/privacy_provider.dart';
import 'package:sure_mobile/screens/receipt_capture_screen.dart';
import 'package:sure_mobile/services/preferences_service.dart';
import 'package:sure_mobile/services/receipts_service.dart';
import 'package:sure_mobile/theme/sure_theme.dart';

void main() {
  final accounts = [
    Account(
        id: 'acct_1',
        name: 'Checking',
        balance: 'PLN 1',
        currency: 'PLN',
        accountType: 'depository'),
    Account(
        id: 'acct_2',
        name: 'Revolut',
        balance: '€250.40',
        currency: 'EUR',
        accountType: 'depository'),
  ];
  final photo = XFile.fromData(Uint8List.fromList([0xFF, 0xD8]),
      path: '/photos/r.jpg', mimeType: 'image/jpeg');

  setUp(() {
    PreferencesService.resetForTest();
  });

  Future<void> pump(
    WidgetTester tester, {
    List<String>? uploadedTo,
    String? initialAccountId,
    Future<List<XFile>?> Function(int maxPages)? scanDocument,
    Future<List<XFile>> Function()? pickFromGallery,
    bool hideAmounts = false,
  }) async {
    await tester.pumpWidget(ChangeNotifierProvider<PrivacyProvider>(
        create: (_) => PrivacyProvider(initialHidden: hideAmounts),
        child: MaterialApp(
          theme: SureTheme.light,
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: ReceiptCaptureScreen(
            accounts: accounts,
            initialAccountId: initialAccountId,
            accessTokenLoader: () async => 'token',
            scanDocument: scanDocument ?? (_) async => [photo],
            pickFromGallery: pickFromGallery ?? () async => [photo],
            service: ReceiptsService(client: MockClient((request) async {
              uploadedTo
                  ?.add(utf8.decode(request.bodyBytes, allowMalformed: true));
              return http.Response(
                  jsonEncode({
                    'id': 's',
                    'status': 'processing',
                    'account_id': 'acct_2'
                  }),
                  202);
            })),
          ),
        )));
    await tester.pumpAndSettle();
  }

  FilledButton uploadButton(WidgetTester tester) => tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Upload receipt'));

  testWidgets('upload is disabled until a photo is picked', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await pump(tester);

    expect(uploadButton(tester).onPressed, isNull);

    await tester.tap(find.text('Take photo'));
    await tester.pumpAndSettle();

    expect(uploadButton(tester).onPressed, isNotNull);
  });

  testWidgets('preselects the last account used', (tester) async {
    SharedPreferences.setMockInitialValues(
        {'receipt_last_account_id': 'acct_2'});
    await pump(tester);

    expect(find.text('Revolut'), findsOneWidget);
    expect(find.text('Checking'), findsNothing);
  });

  testWidgets('uploads to the selected account and remembers it',
      (tester) async {
    SharedPreferences.setMockInitialValues(
        {'receipt_last_account_id': 'acct_2'});
    final bodies = <String>[];
    await pump(tester, uploadedTo: bodies);

    await tester.tap(find.text('Take photo'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Upload receipt'));
    await tester.pumpAndSettle();

    expect(bodies.single, contains('acct_2'));
    expect(
        await PreferencesService.instance.getLastReceiptAccountId(), 'acct_2');
  });

  testWidgets('an initial account wins over the last one used', (tester) async {
    SharedPreferences.setMockInitialValues(
        {'receipt_last_account_id': 'acct_2'});
    await pump(tester, initialAccountId: 'acct_1');

    expect(find.text('Checking'), findsOneWidget);
    expect(find.text('Revolut'), findsNothing);
  });

  testWidgets('camera opens the document scanner for the remaining photo slots',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final limits = <int>[];
    await pump(tester, scanDocument: (maxPages) async {
      limits.add(maxPages);
      return [photo, photo];
    });

    await tester.tap(find.text('Take photo'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Take photo'));
    await tester.pumpAndSettle();

    expect(limits, [5, 3]);
  });

  testWidgets('a cancelled scan adds nothing', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await pump(tester, scanDocument: (_) async => null);

    await tester.tap(find.text('Take photo'));
    await tester.pumpAndSettle();

    expect(uploadButton(tester).onPressed, isNull);
  });

  testWidgets('a scanner failure is reported', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await pump(tester, scanDocument: (_) async => throw Exception('no camera'));

    await tester.tap(find.text('Take photo'));
    await tester.pumpAndSettle();

    expect(find.textContaining("Couldn't open the scanner"), findsOneWidget);
    expect(uploadButton(tester).onPressed, isNull);
  });

  testWidgets('a gallery failure is reported', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await pump(tester, pickFromGallery: () async => throw Exception('no access'));

    await tester.tap(find.text('Choose from gallery'));
    await tester.pumpAndSettle();

    expect(find.textContaining("Couldn't open your photos"), findsOneWidget);
    expect(uploadButton(tester).onPressed, isNull);
  });

  testWidgets('the account picker shows each balance and currency',
      (tester) async {
    SharedPreferences.setMockInitialValues(
        {'receipt_last_account_id': 'acct_2'});
    await pump(tester);

    expect(find.text('€250.40'), findsOneWidget);
    expect(find.text('EUR'), findsOneWidget);
  });

  testWidgets('the account picker masks balances in privacy mode',
      (tester) async {
    SharedPreferences.setMockInitialValues(
        {'receipt_last_account_id': 'acct_2'});
    await pump(tester, hideAmounts: true);

    expect(find.text('€250.40'), findsNothing);
    expect(find.text('€••••'), findsOneWidget);
    expect(find.text('EUR'), findsOneWidget);
  });
}
