import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sure_mobile/l10n/app_localizations.dart';
import 'package:sure_mobile/models/transaction.dart';
import 'package:sure_mobile/theme/sure_theme.dart';
import 'package:sure_mobile/widgets/receipt_status_chip.dart';

void main() {
  Transaction transaction(String? status) => Transaction(
        accountId: 'acct_1',
        name: 'Corner Grocer',
        date: '2026-11-14',
        amount: r'$50.00',
        currency: 'USD',
        nature: 'expense',
        receipt: status == null ? null : TransactionReceipt(status: status),
      );

  Future<void> pump(WidgetTester tester, Transaction t) => tester.pumpWidget(MaterialApp(
        theme: SureTheme.light,
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: Scaffold(body: ReceiptStatusChip(transaction: t)),
      ));

  testWidgets('shows needs review', (tester) async {
    await pump(tester, transaction('needs_review'));
    expect(find.text('Needs review'), findsOneWidget);
  });

  testWidgets('shows a receipt that could not be read', (tester) async {
    await pump(tester, transaction('failed'));
    expect(find.text("Couldn't read the receipt"), findsOneWidget);
  });

  testWidgets('shows processing', (tester) async {
    await pump(tester, transaction('processing'));
    expect(find.text('Processing receipt…'), findsOneWidget);
  });

  testWidgets('shows nothing for a read receipt or no receipt', (tester) async {
    await pump(tester, transaction('completed'));
    expect(find.byType(Text), findsNothing);

    await pump(tester, transaction(null));
    expect(find.byType(Text), findsNothing);
  });
}
