import 'package:flutter_test/flutter_test.dart';
import 'package:sure_mobile/models/amount_format.dart';
import 'package:sure_mobile/utils/money_formatter.dart';

void main() {
  const english = AmountFormat(
    key: 'language',
    grouping: 'standard',
    delimiter: ',',
    separator: '.',
    symbolPosition: 'before',
    symbolSpacing: '',
  );

  const indian = AmountFormat(
    key: 'indian',
    grouping: 'indian',
    delimiter: ',',
    separator: '.',
    symbolPosition: 'before',
    symbolSpacing: '',
  );

  const european = AmountFormat(
    key: 'european',
    grouping: 'standard',
    delimiter: '.',
    separator: ',',
    symbolPosition: 'after',
    symbolSpacing: ' ',
  );

  group('MoneyFormatter.decimal', () {
    test('groups in threes with dot decimals', () {
      expect(MoneyFormatter.decimal(1234567.89, english), '1,234,567.89');
      expect(MoneyFormatter.decimal(999, english), '999');
      expect(
          MoneyFormatter.decimal(1000, english, maxFractionDigits: 0), '1,000');
    });

    test('groups Indian lakh/crore style', () {
      expect(MoneyFormatter.decimal(1234567.89, indian), '12,34,567.89');
      expect(MoneyFormatter.decimal(12345, indian, maxFractionDigits: 0),
          '12,345');
      expect(MoneyFormatter.decimal(123, indian, maxFractionDigits: 0), '123');
    });

    test('uses the European delimiters', () {
      expect(MoneyFormatter.decimal(1234567.89, european), '1.234.567,89');
      expect(MoneyFormatter.decimal(0.5, european), '0,5');
    });

    test('supports space and non-breaking-space delimiters', () {
      const polish = AmountFormat(delimiter: ' ', separator: ',');
      const french = AmountFormat(delimiter: '\u00A0', separator: ',');

      expect(MoneyFormatter.decimal(1234567.89, polish), '1 234 567,89');
      expect(
          MoneyFormatter.decimal(1234567.89, french), '1\u00A0234\u00A0567,89');
    });

    test('rounds before grouping and carries into the next integer', () {
      expect(MoneyFormatter.decimal(1.999, english), '2');
      expect(MoneyFormatter.decimal(1234.999, english), '1,235');
      expect(MoneyFormatter.decimal(0.005, english), '0.01');
    });

    test('trims trailing zeros but can keep or pad them', () {
      expect(MoneyFormatter.decimal(1234.5, english), '1,234.5');
      expect(
        MoneyFormatter.decimal(1234.5, english, keepTrailingZeros: true),
        '1,234.50',
      );
      expect(
        MoneyFormatter.decimal(12, english, minFractionDigits: 2),
        '12.00',
      );
    });

    test('supports negatives and zero', () {
      expect(MoneyFormatter.decimal(-1234567.89, english), '-1,234,567.89');
      expect(MoneyFormatter.decimal(-1234567.89, indian), '-12,34,567.89');
      expect(MoneyFormatter.decimal(0, english), '0');
      expect(MoneyFormatter.decimal(0, english, minFractionDigits: 2), '0.00');
    });

    test('supports up to eight decimals for crypto-style amounts', () {
      expect(
        MoneyFormatter.decimal(0.12345678, english, maxFractionDigits: 8),
        '0.12345678',
      );
    });
  });

  group('MoneyFormatter.currency', () {
    test('places the symbol before the amount with server spacing', () {
      expect(
        MoneyFormatter.currency(1234.56, english, symbol: r'$'),
        r'$1,234.56',
      );
    });

    test('places the symbol after the amount with server spacing', () {
      expect(
        MoneyFormatter.currency(1234.56, european, symbol: '€'),
        '1.234,56 €',
      );
    });

    test('supports an empty or non-breaking-space symbol spacing', () {
      const euroBefore = AmountFormat(delimiter: '.', separator: ',');
      const euroAfterNbsp = AmountFormat(
        delimiter: '.',
        separator: ',',
        symbolPosition: 'after',
        symbolSpacing: '\u00A0',
      );

      expect(
        MoneyFormatter.currency(1234.56, euroBefore, symbol: '€'),
        '€1.234,56',
      );
      expect(
        MoneyFormatter.currency(1234.56, euroAfterNbsp, symbol: '€'),
        '1.234,56\u00A0€',
      );
    });

    test('keeps the minus sign outside the symbol', () {
      expect(
        MoneyFormatter.currency(-1234.56, english, symbol: r'$'),
        r'-$1,234.56',
      );
      expect(
        MoneyFormatter.currency(-1234.56, european, symbol: '€'),
        '-1.234,56 €',
      );
    });

    test('supports zero-decimal formatting', () {
      expect(
        MoneyFormatter.currency(1234567, indian,
            symbol: '₹', maxFractionDigits: 0),
        '₹12,34,567',
      );
    });
  });
}
