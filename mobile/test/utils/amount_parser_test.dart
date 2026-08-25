import 'package:flutter_test/flutter_test.dart';
import 'package:sure_mobile/utils/amount_parser.dart';

void main() {
  group('AmountParser', () {
    test('parses decimal-comma currency values', () {
      final amount = AmountParser.parse('Rp1.234,56', locale: 'id_ID');

      expect(amount.value, 1234.56);
      expect(amount.canonicalValue, '1234.56');
      expect(amount.displayText, 'Rp1.234,56');
    });

    test('parses grouped zero-decimal locale values as whole amounts', () {
      final amount = AmountParser.parse('1.234.567', locale: 'id_ID');

      expect(amount.value, 1234567);
      expect(amount.canonicalValue, '1234567');
    });

    test('parses decimal-dot currency values', () {
      final amount = AmountParser.parse(r'$1,234.56', locale: 'en_US');

      expect(amount.value, 1234.56);
      expect(amount.canonicalValue, '1234.56');
      expect(amount.displayText, r'$1,234.56');
    });

    test('uses locale separators for ambiguous single separators', () {
      expect(
        AmountParser.parse('1.234', locale: 'id_ID').canonicalValue,
        '1234',
      );
      expect(
        AmountParser.parse('1.234', locale: 'en_US').canonicalValue,
        '1.234',
      );
    });

    test('normalizes minus variants and removes sign from display text', () {
      final amount = AmountParser.parse('\u2212Rp1.234,50', locale: 'id_ID');

      expect(amount.value, -1234.5);
      expect(amount.canonicalValue, '-1234.5');
      expect(amount.displayText, 'Rp1.234,50');
    });

    test('removes embedded and trailing signs from display text', () {
      expect(
        AmountParser.parse('Rp-1.234,50', locale: 'id_ID').displayText,
        'Rp1.234,50',
      );
      expect(
        AmountParser.parse('Rp1.234,50-', locale: 'id_ID').displayText,
        'Rp1.234,50',
      );
    });

    test('canonicalizes transaction form input for API payloads', () {
      expect(AmountParser.canonicalize('1.234,50', locale: 'id_ID'), '1234.5');
      expect(AmountParser.canonicalize('1,234.50', locale: 'en_US'), '1234.5');
    });

    test('rejects repeated separators that are not grouped', () {
      expect(
        () => AmountParser.parse('1.2.3', locale: 'en_US'),
        throwsFormatException,
      );
      expect(
        () => AmountParser.parse('1,2,3', locale: 'id_ID'),
        throwsFormatException,
      );
    });

    test('rejects inputs without digits', () {
      expect(
        () => AmountParser.parse('USD', locale: 'en_US'),
        throwsFormatException,
      );
    });
  });
}
