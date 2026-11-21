import 'package:flutter_test/flutter_test.dart';
import 'package:sure_mobile/models/account.dart';

Account accountWithBalance(String balance) {
  return Account(
    id: 'account-1',
    name: 'Checking',
    balance: balance,
    currency: 'USD',
    accountType: 'depository',
  );
}

void main() {
  group('Account.balanceAsDouble', () {
    test('parses dollar amounts with comma grouping', () {
      expect(accountWithBalance(r'$1,234.56').balanceAsDouble, 1234.56);
      expect(accountWithBalance(r'-$1,234.56').balanceAsDouble, -1234.56);
      expect(accountWithBalance(r'$1,234,567.89').balanceAsDouble, 1234567.89);
    });

    test('parses European amounts with dot grouping and comma decimals', () {
      expect(accountWithBalance('1.234,56 €').balanceAsDouble, 1234.56);
      expect(accountWithBalance('1.234.567,89 €').balanceAsDouble, 1234567.89);
      expect(accountWithBalance('-1.234,56 €').balanceAsDouble, -1234.56);
    });

    test('parses Indian lakh/crore amounts', () {
      expect(accountWithBalance('₹12,34,567.89').balanceAsDouble, 1234567.89);
      expect(accountWithBalance('₹12,34,567').balanceAsDouble, 1234567);
      expect(accountWithBalance('₹1,23,456').balanceAsDouble, 123456);
    });

    test('parses space and non-breaking-space grouping', () {
      expect(accountWithBalance('1 234,56 €').balanceAsDouble, 1234.56);
      expect(
          accountWithBalance('1\u00A0234,56\u00A0€').balanceAsDouble, 1234.56);
    });

    test('parses zero-decimal currencies', () {
      expect(accountWithBalance('¥1,234,567').balanceAsDouble, 1234567);
    });

    test('parses plain values and decimals', () {
      expect(accountWithBalance('1234').balanceAsDouble, 1234);
      expect(accountWithBalance('1234.5').balanceAsDouble, 1234.5);
      expect(accountWithBalance('1234,5').balanceAsDouble, 1234.5);
      expect(accountWithBalance('1,234').balanceAsDouble, 1234);
      expect(accountWithBalance('1.234').balanceAsDouble, 1234);
    });

    test('returns zero for unparseable or empty balances', () {
      expect(accountWithBalance('').balanceAsDouble, 0);
      expect(accountWithBalance('n/a').balanceAsDouble, 0);
    });
  });
}
