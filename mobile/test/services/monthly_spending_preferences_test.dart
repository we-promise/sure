import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sure_mobile/models/monthly_spending.dart';
import 'package:sure_mobile/services/monthly_spending_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test('selection is isolated by server and user and preserves explicit none',
      () async {
    const selection = MonthlySpendingSelection(
        period: 'last_twelve', accountIds: [], categoryIds: ['food']);
    await MonthlySpendingPreferences.save('server-a:user-a', selection);
    expect(await MonthlySpendingPreferences.load('server-b:user-a'), isNull);
    expect(await MonthlySpendingPreferences.load('server-a:user-b'), isNull);
    final restored =
        (await MonthlySpendingPreferences.load('server-a:user-a'))!;
    expect(restored.accountIds, isEmpty);
    expect(restored.categoryIds, ['food']);
    expect(restored.resolved(DateTime(2026, 1)).from, isNull);
    expect(restored.resolved(DateTime(2026, 1)).query['account_ids[]'], ['']);
  });
  test('rolling year follows January while custom dates stay fixed', () {
    const rolling = MonthlySpendingSelection(
        period: 'this_year', from: '2025-01-01', to: '2025-12-01');
    expect(rolling.resolved(DateTime(2026, 1)).from, '2026-01-01');
    expect(rolling.resolved(DateTime(2026, 1)).to, '2026-01-01');
    const custom = MonthlySpendingSelection(
        period: 'custom', from: '2025-02-01', to: '2025-04-01');
    expect(custom.resolved(DateTime(2026, 1)).from, '2025-02-01');
  });
  test('corrupt saved settings do not break Home', () async {
    SharedPreferences.setMockInitialValues(
        {'monthly_spending:server:user': 'invalid'});
    expect(await MonthlySpendingPreferences.load('server:user'), isNull);
  });
}
