// ignore_for_file: deprecated_member_use

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sure_mobile/theme/sure_tokens.dart';

void main() {
  late Map<String, dynamic> tokens;

  setUpAll(() {
    tokens =
        jsonDecode(_tokensFile().readAsStringSync()) as Map<String, dynamic>;
  });

  test('generated tokens keep the canonical token version', () {
    expect(SureTokens.version, tokens[r'$version']);
  });

  test(
    'generated light and dark colors match representative canonical tokens',
    () {
      expect(
        SureTokens.light.surface.value,
        _resolveColor(tokens, 'color.surface', dark: false),
      );
      expect(
        SureTokens.dark.surface.value,
        _resolveColor(tokens, 'color.surface', dark: true),
      );
      expect(
        SureTokens.light.textPrimary.value,
        _resolveColor(tokens, 'utility.text-primary', dark: false),
      );
      expect(
        SureTokens.dark.textPrimary.value,
        _resolveColor(tokens, 'utility.text-primary', dark: true),
      );
      expect(
        SureTokens.light.destructive.value,
        _resolveColor(tokens, 'color.destructive', dark: false),
      );
      expect(
        SureTokens.dark.destructive.value,
        _resolveColor(tokens, 'color.destructive', dark: true),
      );
    },
  );

  test('generated radii match canonical dimensions', () {
    expect(SureTokens.radiusMd, _resolveDimension(tokens, 'border.radius.md'));
    expect(SureTokens.radiusLg, _resolveDimension(tokens, 'border.radius.lg'));
  });

  test('generated font weights match canonical tiers', () {
    expect(
      SureTokens.weightMedium.value,
      _resolveWeight(tokens, 'font.weight.medium'),
    );
    expect(
      SureTokens.weightSemibold.value,
      _resolveWeight(tokens, 'font.weight.semibold'),
    );
  });

  test('generated focus-ring and bg-inverse match canonical tokens', () {
    expect(
      SureTokens.light.focusRing.value,
      _resolveColor(tokens, 'color.focus-ring', dark: false),
    );
    expect(
      SureTokens.dark.focusRing.value,
      _resolveColor(tokens, 'color.focus-ring', dark: true),
    );
    expect(
      SureTokens.light.bgInverse.value,
      _resolveColor(tokens, 'utility.bg-inverse', dark: false),
    );
    expect(
      SureTokens.dark.bgInverse.value,
      _resolveColor(tokens, 'utility.bg-inverse', dark: true),
    );
  });

  test('generated shadow scale carries mode-aware color and geometry', () {
    final lightSm = SureTokens.light.shadowSm.single;
    expect(lightSm.offset, const Offset(0, 1));
    expect(lightSm.blurRadius, 6.0);
    expect(lightSm.spreadRadius, 0.0);
    expect(
      lightSm.color.value,
      _resolveColorValue(tokens, '{color.black|6%}', dark: false),
    );
    expect(
      SureTokens.dark.shadowSm.single.color.value,
      _resolveColorValue(tokens, '{color.white|8%}', dark: true),
    );
    // The xl step keeps the canonical negative spread (0px 20px 24px -4px).
    expect(SureTokens.light.shadowXl.single.spreadRadius, -4.0);
  });
}

int _resolveColor(
  Map<String, dynamic> tokens,
  String path, {
  required bool dark,
}) {
  final node = _nodeAt(tokens, path);
  final extensions = node[r'$extensions'] as Map<String, dynamic>?;
  final value = dark && extensions != null && extensions['sure.dark'] != null
      ? extensions['sure.dark'] as String
      : node[r'$value'] as String;

  return _resolveColorValue(tokens, value, dark: dark);
}

int _resolveColorValue(
  Map<String, dynamic> tokens,
  String value, {
  required bool dark,
}) {
  final hex = RegExp(r'^#([0-9a-fA-F]{6})$').firstMatch(value);
  if (hex != null) {
    return int.parse('FF${hex.group(1)!}', radix: 16);
  }

  final ref = RegExp(r'^\{([^|}]+)(?:\|([0-9]+)%?)?\}$').firstMatch(value);
  if (ref != null) {
    final resolved = _resolveColor(tokens, ref.group(1)!, dark: dark);
    final alphaPercent = ref.group(2);
    if (alphaPercent == null) return resolved;

    final alpha = ((int.parse(alphaPercent) / 100) * 255).round();
    return (alpha << 24) | (resolved & 0x00FFFFFF);
  }

  throw StateError('Unsupported color value: $value');
}

int _resolveWeight(Map<String, dynamic> tokens, String path) {
  return _nodeAt(tokens, path)[r'$value'] as int;
}

double _resolveDimension(Map<String, dynamic> tokens, String path) {
  final value = _nodeAt(tokens, path)[r'$value'] as String;
  final match = RegExp(r'^([0-9]+(?:\.[0-9]+)?)px$').firstMatch(value);
  if (match == null) throw StateError('Unsupported dimension value: $value');

  return double.parse(match.group(1)!);
}

Map<String, dynamic> _nodeAt(Map<String, dynamic> tokens, String path) {
  dynamic current = tokens;
  for (final part in path.split('.')) {
    current = current[part];
  }

  return current as Map<String, dynamic>;
}

File _tokensFile() {
  var directory = Directory.current;

  for (var depth = 0; depth < 4; depth += 1) {
    final file = File('${directory.path}/design/tokens/sure.tokens.json');
    if (file.existsSync()) return file;

    directory = directory.parent;
  }

  throw StateError('Could not locate design/tokens/sure.tokens.json');
}
