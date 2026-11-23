import 'package:flutter_test/flutter_test.dart';
import 'package:sure_mobile/services/app_lock_guard.dart';

void main() {
  late DateTime now;
  late AppLockGuard guard;

  setUp(() {
    now = DateTime(2026, 11, 23, 12);
    guard = AppLockGuard(clock: () => now);
  });

  test('locks when the app goes to the background on its own', () {
    expect(guard.shouldLockOnPause(), isTrue);
    expect(guard.shouldLockOnResume(), isFalse);
  });

  test('stays unlocked while a native screen the app opened is showing',
      () async {
    await guard.whileNativeScreenOpen(() async {
      expect(guard.shouldLockOnPause(), isFalse);
      now = now.add(const Duration(minutes: 1));
      expect(guard.shouldLockOnResume(), isFalse);
    });

    expect(guard.shouldLockOnPause(), isTrue);
  });

  test('locks on return when the native screen kept the app away too long',
      () async {
    await guard.whileNativeScreenOpen(() async {
      expect(guard.shouldLockOnPause(), isFalse);
      now = now.add(AppLockGuard.grace + const Duration(seconds: 1));
    });

    expect(guard.shouldLockOnResume(), isTrue);
    expect(guard.shouldLockOnResume(), isFalse);
  });

  test('ends the exemption when the native screen fails', () async {
    await expectLater(
      guard.whileNativeScreenOpen(() async => throw StateError('scanner')),
      throwsStateError,
    );

    expect(guard.shouldLockOnPause(), isTrue);
  });
}
