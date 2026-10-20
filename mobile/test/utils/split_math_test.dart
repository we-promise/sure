import 'package:flutter_test/flutter_test.dart';
import 'package:sure_mobile/utils/split_math.dart';

BigInt u(String value) => SplitMath.parseUnits(value)!;

void main() {
  group('SplitMath.parseUnits', () {
    test('parses plain decimals into 1/10000 units', () {
      expect(u('12.5'), BigInt.from(125000));
      expect(u('-0.0001'), BigInt.from(-1));
      expect(u('100'), BigInt.from(1000000));
      expect(u('.5'), BigInt.from(5000));
    });

    test('accepts the API decimal(19,4) strings and exponents', () {
      expect(u('33.3333'), BigInt.from(333333));
      expect(u('100.0'), BigInt.from(1000000));
      expect(u('0.1e3'), BigInt.from(1000000));
      expect(u('1.50000'), BigInt.from(15000));
    });

    test('rejects garbage and more than four significant decimals', () {
      expect(SplitMath.parseUnits(''), isNull);
      expect(SplitMath.parseUnits('abc'), isNull);
      expect(SplitMath.parseUnits('1.2.3'), isNull);
      expect(SplitMath.parseUnits('0.00001'), isNull);
    });
  });

  group('SplitMath.parseUserInput', () {
    test('rejects signs that are not a single leading sign', () {
      expect(SplitMath.parseUserInput('12\u22123', locale: 'en'), isNull);
      expect(SplitMath.parseUserInput('1\u2212', locale: 'en'), isNull);
      expect(SplitMath.parseUserInput('--5', locale: 'en'), isNull);
      expect(SplitMath.parseUserInput('\u22125', locale: 'en'),
          BigInt.from(-50000));
    });
    test('handles grouping and the locale decimal separator', () {
      expect(
        SplitMath.parseUserInput('1,234.56', locale: 'en'),
        BigInt.from(12345600),
      );
      expect(
        SplitMath.parseUserInput('1.234,56', locale: 'sv'),
        BigInt.from(12345600),
      );
      expect(
        SplitMath.parseUserInput('1\u00A0234,56', locale: 'sv'),
        BigInt.from(12345600),
      );
      expect(SplitMath.parseUserInput('-12', locale: 'en'), u('-12'));
      expect(SplitMath.parseUserInput('12abc', locale: 'en'), isNull);
    });
  });

  group('currency precision', () {
    test('knows zero- and three-decimal currencies', () {
      expect(SplitMath.currencyDecimals('USD'), 2);
      expect(SplitMath.currencyDecimals('JPY'), 0);
      expect(SplitMath.currencyDecimals('KWD'), 3);
      expect(SplitMath.currencyDecimals(''), 2);
    });

    test('widens input precision only for a finer stored parent amount', () {
      expect(SplitMath.inputDecimals('USD', u('100.00')), 2);
      expect(SplitMath.inputDecimals('USD', u('100.125')), 3);
      expect(SplitMath.inputDecimals('JPY', u('1500')), 0);
    });

    test('validateAmount reports the first problem', () {
      expect(
        SplitMath.validateAmount('', decimals: 2, locale: 'en'),
        SplitAmountError.required,
      );
      expect(
        SplitMath.validateAmount('abc', decimals: 2, locale: 'en'),
        SplitAmountError.invalid,
      );
      expect(
        SplitMath.validateAmount('0.00', decimals: 2, locale: 'en'),
        SplitAmountError.zero,
      );
      expect(
        SplitMath.validateAmount('10.005', decimals: 2, locale: 'en'),
        SplitAmountError.tooPrecise,
      );
      expect(
        SplitMath.validateAmount('10.5', decimals: 0, locale: 'en'),
        SplitAmountError.tooPrecise,
      );
      expect(
        SplitMath.validateAmount('10.50', decimals: 2, locale: 'en'),
        isNull,
      );
    });
  });

  group('remaining', () {
    test('is exact where doubles are not', () {
      // 0.1 + 0.2 != 0.3 in floating point; it must balance here.
      final remaining = SplitMath.remaining(
        u('0.3'),
        ['0.1', '0.2'],
        locale: 'en',
      );
      expect(remaining, BigInt.zero);
    });

    test('ignores unparseable rows and goes negative when over-allocated', () {
      expect(
        SplitMath.remaining(u('100'), ['60', '', 'x'], locale: 'en'),
        u('40'),
      );
      expect(
        SplitMath.remaining(u('100'), ['60', '50'], locale: 'en'),
        u('-10'),
      );
    });
  });

  group('formatting', () {
    test('toDecimalString keeps exact values', () {
      expect(SplitMath.toDecimalString(u('60')), '60.0000');
      expect(SplitMath.toDecimalString(u('60'), decimals: 2), '60.00');
      expect(SplitMath.toDecimalString(u('-0.5'), decimals: 0), '-0.5');
      expect(SplitMath.toDecimalString(u('1500'), decimals: 0), '1500');
    });

    test('formatMoney uses the currency precision', () {
      expect(
        SplitMath.formatMoney(u('1234.5'), 'USD', decimals: 2, locale: 'en'),
        r'$1,234.50',
      );
      expect(
        SplitMath.formatMoney(u('1500'), 'JPY', decimals: 0, locale: 'en'),
        contains('1,500'),
      );
    });
  });
}
