import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sure_mobile/l10n/app_localizations.dart';
import 'package:sure_mobile/screens/login_screen.dart';

void main() {
  // Opens the dialog with an injected controller and returns it so the test can
  // assert the dialog disposed it. A disposed ChangeNotifier throws when used
  // again, which is how we verify disposal.
  Future<TextEditingController> openDialog(WidgetTester tester) async {
    final controller = TextEditingController();
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => showDialog<bool>(
                context: context,
                builder: (_) => ApiKeyLoginDialog(controller: controller),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('API Key Login'), findsOneWidget);
    return controller;
  }

  void expectDisposed(TextEditingController controller) {
    expect(() => controller.addListener(() {}), throwsA(isA<FlutterError>()));
  }

  testWidgets('disposes its controller when cancelled', (tester) async {
    final controller = await openDialog(tester);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(find.text('API Key Login'), findsNothing);
    expectDisposed(controller);
  });

  testWidgets('disposes its controller when dismissed by a barrier tap',
      (tester) async {
    final controller = await openDialog(tester);

    // The barrier fills the screen but its centre is occluded by the dialog, so
    // tap halfway between the screen corner and the dialog's top-left — a point
    // derived from the dialog's real geometry (not a fixed coordinate) that is
    // always on the dismissible barrier.
    final dialogTopLeft = tester.getTopLeft(find.byType(AlertDialog));
    await tester.tapAt(dialogTopLeft / 2);
    await tester.pumpAndSettle();

    expect(find.text('API Key Login'), findsNothing);
    expectDisposed(controller);
  });

  testWidgets('disposes its controller when dismissed by the system back button',
      (tester) async {
    final controller = await openDialog(tester);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(find.text('API Key Login'), findsNothing);
    expectDisposed(controller);
  });
}
