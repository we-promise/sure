import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sure_mobile/l10n/app_localizations.dart';
import 'package:sure_mobile/models/transaction.dart';
import 'package:sure_mobile/theme/sure_theme.dart';
import 'package:sure_mobile/widgets/receipt_details_section.dart';

void main() {
  Future<void> pump(WidgetTester tester, TransactionReceipt? receipt,
          {Map<String, String>? headers, bool hideAmounts = false}) =>
      tester.pumpWidget(MaterialApp(
        theme: SureTheme.light,
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: Scaffold(
            body: ReceiptDetailsSection(
                receipt: receipt,
                imageHeaders: headers,
                hideAmounts: hideAmounts)),
      ));

  testWidgets('lists items, review reasons and the status', (tester) async {
    await pump(
      tester,
      TransactionReceipt(
        status: 'needs_review',
        reviewReasons: const ['items_total_mismatch'],
        lineItems: const [
          ReceiptLineItem(
              name: 'Cheese', amount: '30.00', categoryName: 'Food & Drink')
        ],
      ),
    );

    expect(find.text('Receipt'), findsOneWidget);
    expect(find.text('Needs review'), findsOneWidget);
    expect(find.text('Items total mismatch'), findsOneWidget);
    expect(find.text('Cheese'), findsOneWidget);
    expect(find.text('Food & Drink'), findsOneWidget);
    expect(find.text('30.00'), findsOneWidget);
  });

  testWidgets('masks item amounts when amounts are hidden', (tester) async {
    await pump(
      tester,
      TransactionReceipt(
        status: 'completed',
        lineItems: const [
          ReceiptLineItem(
              name: 'Cheese', amount: '30.00', categoryName: 'Food & Drink')
        ],
      ),
      hideAmounts: true,
    );

    expect(find.text('30.00'), findsNothing);
    expect(find.text('••••'), findsOneWidget);
  });

  testWidgets('renders nothing without a receipt', (tester) async {
    await pump(tester, null);

    expect(find.text('Receipt'), findsNothing);
  });

  testWidgets('loads receipt photos with the API credentials', (tester) async {
    await pump(
      tester,
      TransactionReceipt(
        status: 'completed',
        attachments: const [
          TransactionAttachment(
            url: 'https://sure.test/api/v1/transactions/t/attachments/a',
            thumbnailUrl:
                'https://sure.test/api/v1/transactions/t/attachments/a?variant=thumbnail',
            contentType: 'image/jpeg',
            filename: 'r.jpg',
          ),
        ],
      ),
      headers: const {'X-Api-Key': 'key'},
    );

    final image =
        tester.widget<Image>(find.byType(Image)).image as NetworkImage;
    expect(image.url, endsWith('?variant=thumbnail'));
    expect(image.headers, {'X-Api-Key': 'key'});
  });

  testWidgets('waits for the API credentials before loading receipt photos',
      (tester) async {
    await pump(
      tester,
      TransactionReceipt(
        status: 'completed',
        attachments: const [
          TransactionAttachment(
            url: 'https://sure.test/api/v1/transactions/t/attachments/a',
            contentType: 'image/jpeg',
            filename: 'r.jpg',
          ),
        ],
        lineItems: const [ReceiptLineItem(name: 'Cheese', amount: '30.00')],
      ),
    );

    expect(find.byType(Image), findsNothing);
    expect(find.byIcon(Icons.receipt_long_outlined), findsOneWidget);
    expect(find.text('Cheese'), findsOneWidget);
  });
}
