import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android versionCode stays above the last published release', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final versionMatch = RegExp(r'^version:\s*([^\s]+)$', multiLine: true).firstMatch(pubspec);

    expect(versionMatch, isNotNull);

    final version = versionMatch!.group(1)!;
    final versionParts = version.split('+');

    expect(versionParts.length, 2);

    final versionCode = int.parse(versionParts[1]);

    expect(
      versionCode,
      greaterThan(11),
      reason: 'Android upgrades require monotonically increasing versionCode values; v0.6.8 shipped with versionCode 11.',
    );
  });
}
