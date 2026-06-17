import 'package:flutter_test/flutter_test.dart';
import 'package:sure_mobile/utils/money_masker.dart';

void main() {
  group('MoneyMasker.mask', () {
    test('collapses the numeric portion into a fixed run, keeping symbol/sign', () {
      expect(MoneyMasker.mask(r'$29,669.71'), r'$••••');
      expect(MoneyMasker.mask(r'CA$42,078.35'), r'CA$••••');
      expect(MoneyMasker.mask(r'-$1,234'), r'-$••••');
      expect(MoneyMasker.mask('+CAD 42,078.35'), '+CAD ••••');
    });

    test('hides magnitude — different-sized amounts mask identically', () {
      expect(MoneyMasker.mask(r'$5.00'), MoneyMasker.mask(r'$5,000,000.00'));
    });

    test('leaves symbol-only / non-numeric strings untouched', () {
      expect(MoneyMasker.mask('--'), '--');
      expect(MoneyMasker.mask('€0.00'), '€••••');
      expect(MoneyMasker.mask('₿0.40000000'), '₿••••');
    });

    test('returns the input unchanged when hidden is false', () {
      expect(MoneyMasker.mask(r'$29,669.71', hidden: false), r'$29,669.71');
    });

    test('is idempotent on already-masked input', () {
      final once = MoneyMasker.mask(r'$1,234.56');
      expect(MoneyMasker.mask(once), once);
    });
  });
}
