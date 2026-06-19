import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sure_mobile/screens/login_screen.dart';

void main() {
  // Opens the dialog with an injected controller and returns it so the test can
  // assert the dialog disposed it. A disposed ChangeNotifier throws when used
  // again, which is how we verify disposal.
  Future<TextEditingController> openDialog(WidgetTester tester) async {
    final controller = TextEditingController();
    await tester.pumpWidget(
      MaterialApp(
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

    // Tap outside the centered dialog -> the modal barrier dismisses it.
    await tester.tapAt(const Offset(10, 10));
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
