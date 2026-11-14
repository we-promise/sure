import 'package:flutter_test/flutter_test.dart';
import 'package:sure_mobile/models/amount_format.dart';
import 'package:sure_mobile/models/user.dart';

void main() {
  group('User amount format', () {
    test('parses the resolved amount format payload', () {
      final user = User.fromJson({
        'id': 'user-1',
        'email': 'user@example.com',
        'first_name': 'Ada',
        'last_name': 'Lovelace',
        'ui_layout': 'dashboard',
        'ai_enabled': true,
        'amount_format': {
          'key': 'indian',
          'grouping': 'indian',
          'delimiter': ',',
          'separator': '.',
          'symbol_position': 'before',
          'symbol_spacing': '',
        },
      });

      expect(user.amountFormat.key, 'indian');
      expect(user.amountFormat.grouping, 'indian');
      expect(user.amountFormat.delimiter, ',');
      expect(user.amountFormat.separator, '.');
      expect(user.amountFormat.symbolPosition, 'before');
    });

    test('falls back to International rules when the object is missing', () {
      final user = User.fromJson({
        'id': 'user-1',
        'email': 'user@example.com',
        'ui_layout': 'dashboard',
        'ai_enabled': false,
      });

      expect(user.amountFormat.grouping, 'standard');
      expect(user.amountFormat.delimiter, ',');
      expect(user.amountFormat.separator, '.');
      expect(user.amountFormat.symbolPosition, 'before');
      expect(user.amountFormat.symbolSpacing, '');
    });

    test('falls back to International rules for malformed values', () {
      final user = User.fromJson({
        'id': 'user-1',
        'email': 'user@example.com',
        'ui_layout': 'dashboard',
        'ai_enabled': false,
        'amount_format': {
          'key': 'roman',
          'grouping': 'roman',
          'delimiter': 'x',
          'separator': 'y',
          'symbol_position': 'middle',
          'symbol_spacing': 'z',
        },
      });

      expect(user.amountFormat.key, 'language');
      expect(user.amountFormat.grouping, 'standard');
      expect(user.amountFormat.delimiter, ',');
      expect(user.amountFormat.separator, '.');
      expect(user.amountFormat.symbolPosition, 'before');
      expect(user.amountFormat.symbolSpacing, '');
    });

    test('supports camelCase keys from older clients', () {
      final format = AmountFormat.fromJson({
        'key': 'european',
        'grouping': 'standard',
        'delimiter': '.',
        'separator': ',',
        'symbolPosition': 'after',
        'symbolSpacing': ' ',
      });

      expect(format.symbolPosition, 'after');
      expect(format.symbolSpacing, ' ');
    });

    test('round-trips through JSON', () {
      final user = User.fromJson({
        'id': 'user-1',
        'email': 'user@example.com',
        'ui_layout': 'dashboard',
        'ai_enabled': false,
        'amount_format': {
          'key': 'european',
          'grouping': 'standard',
          'delimiter': '.',
          'separator': ',',
          'symbol_position': 'after',
          'symbol_spacing': ' ',
        },
      });

      final json = user.toJson();
      expect(json['amount_format'], {
        'key': 'european',
        'grouping': 'standard',
        'delimiter': '.',
        'separator': ',',
        'symbol_position': 'after',
        'symbol_spacing': ' ',
      });

      final restored = User.fromJson(json);
      expect(restored.amountFormat, user.amountFormat);
    });

    test('copyWith preserves the amount format', () {
      final user = User.fromJson({
        'id': 'user-1',
        'email': 'user@example.com',
        'ui_layout': 'dashboard',
        'ai_enabled': false,
        'amount_format': {
          'key': 'indian',
          'grouping': 'indian',
          'delimiter': ',',
          'separator': '.',
          'symbol_position': 'before',
          'symbol_spacing': '',
        },
      });

      final updated = user.copyWith(firstName: 'Grace');
      expect(updated.amountFormat, user.amountFormat);
    });
  });
}
