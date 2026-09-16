import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../models/account.dart';
import '../models/account_balance.dart';
import '../models/account_holding.dart';
import '../providers/auth_provider.dart';
import '../providers/privacy_provider.dart';
import '../services/account_detail_service.dart';
import '../l10n/app_localizations.dart';
import '../utils/money_masker.dart';

class AccountDetailHeader extends StatefulWidget {
  final Account account;
  final AccountDetailService? accountDetailService;

  const AccountDetailHeader({
    super.key,
    required this.account,
    this.accountDetailService,
  });

  @override
  State<AccountDetailHeader> createState() => _AccountDetailHeaderState();
}

class _AccountDetailHeaderState extends State<AccountDetailHeader> {
  late final AccountDetailService _accountDetailService =
      widget.accountDetailService ?? AccountDetailService();
  late final bool _ownsAccountDetailService =
      widget.accountDetailService == null;
  late Account _account;
  bool _isLoading = false;
  bool _detailsUnavailable = false;
  List<AccountBalance> _balances = [];
  List<AccountHolding> _holdings = [];
  bool _disposed = false;
  bool _accountDetailServiceClosed = false;
  int _activeDetailLoads = 0;

  @override
  void initState() {
    super.initState();
    _account = widget.account;
    _loadDetails();
  }

  Future<void> _loadDetails() async {
    if (_disposed) return;

    // NOTE: this runs synchronously from initState(); do not touch inherited
    // widgets (e.g. AppLocalizations.of) here. The failure message is localized
    // at render time in build() via the _detailsUnavailable flag.
    final authProvider = Provider.of<AuthProvider>(context, listen: false);
    final accessToken = await authProvider.getValidAccessToken();
    if (_disposed) return;

    if (accessToken == null) {
      await authProvider.logout();
      return;
    }

    _activeDetailLoads += 1;

    if (mounted) {
      setState(() {
        _isLoading = true;
        _detailsUnavailable = false;
      });
    }

    try {
      final results = await Future.wait([
        _accountDetailService.getAccountDetail(
          accessToken: accessToken,
          accountId: widget.account.id,
        ),
        _accountDetailService.getBalances(
          accessToken: accessToken,
          accountId: widget.account.id,
        ),
      ]);

      final accountResult = results[0];
      final balancesResult = results[1];
      final resolvedAccount = accountResult['success'] == true &&
              accountResult['account'] is Account
          ? accountResult['account'] as Account
          : _account;

      Map<String, dynamic>? holdingsResult;
      if (_supportsHoldings(resolvedAccount)) {
        holdingsResult = await _accountDetailService.getHoldings(
          accessToken: accessToken,
          accountId: widget.account.id,
        );
      }

      if (!mounted || _disposed) return;

      if (accountResult['error'] == 'unauthorized' ||
          balancesResult['error'] == 'unauthorized' ||
          holdingsResult?['error'] == 'unauthorized') {
        await authProvider.logout();
        return;
      }

      setState(() {
        if (accountResult['success'] == true &&
            accountResult['account'] is Account) {
          _account = resolvedAccount;
        }
        if (balancesResult['success'] == true) {
          _balances = (balancesResult['balances'] as List<dynamic>? ?? [])
              .whereType<AccountBalance>()
              .toList();
        }
        if (holdingsResult?['success'] == true) {
          _holdings = (holdingsResult?['holdings'] as List<dynamic>? ?? [])
              .whereType<AccountHolding>()
              .toList();
        }
        if (accountResult['success'] != true &&
            balancesResult['success'] != true) {
          _detailsUnavailable = true;
        }
        _isLoading = false;
      });
    } finally {
      _activeDetailLoads -= 1;
      _closeOwnedAccountDetailServiceIfIdle();
    }
  }

  bool _supportsHoldings(Account account) {
    return account.accountType == 'investment' ||
        account.accountType == 'crypto';
  }

  @override
  void dispose() {
    _disposed = true;
    _closeOwnedAccountDetailServiceIfIdle();
    super.dispose();
  }

  void _closeOwnedAccountDetailServiceIfIdle() {
    if (_ownsAccountDetailService &&
        _disposed &&
        _activeDetailLoads == 0 &&
        !_accountDetailServiceClosed) {
      _accountDetailService.close();
      _accountDetailServiceClosed = true;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    final latestBalance = _balances.isNotEmpty ? _balances.first : null;
    final hideAmounts = context.watch<PrivacyProvider>().hidden;

    return Card(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _account.displayAccountType,
                        style: Theme.of(context).textTheme.labelLarge?.copyWith(
                              color: colorScheme.onSurfaceVariant,
                            ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        MoneyMasker.mask(_account.balance, hidden: hideAmounts),
                        style: Theme.of(context)
                            .textTheme
                            .headlineSmall
                            ?.copyWith(
                              fontWeight: FontWeight.bold,
                              color: _account.isLiability ? Colors.red : null,
                            ),
                      ),
                    ],
                  ),
                ),
                if (_isLoading)
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  IconButton(
                    icon: const Icon(Icons.refresh),
                    tooltip: l.accountDetailRefreshTooltip,
                    onPressed: _loadDetails,
                  ),
              ],
            ),
            if (_account.institutionName != null ||
                _account.subtype != null ||
                _account.cashBalance != null ||
                _account.status != null) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (_account.institutionName != null)
                    _DetailChip(
                      label: _account.institutionName!,
                      icon: Icons.account_balance,
                    ),
                  if (_account.subtype != null)
                    _DetailChip(
                      label: _account.subtype!,
                      icon: Icons.category_outlined,
                    ),
                  if (_account.cashBalance != null)
                    _DetailChip(
                      label: l.accountDetailCashChip(
                        MoneyMasker.mask(_account.cashBalance!,
                            hidden: hideAmounts),
                      ),
                      icon: Icons.payments_outlined,
                    ),
                  if (_account.status != null)
                    _DetailChip(
                      label: _account.status!,
                      icon: Icons.sync,
                    ),
                ],
              ),
            ],
            if (_balances.length >= 2) ...[
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      l.accountDetailRecentBalanceHistory,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                  Text(
                    latestBalance == null
                        ? ''
                        : DateFormat.yMMMd(
                            Localizations.localeOf(context).toString(),
                          ).format(latestBalance.date),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: 56,
                child: _BalanceSparkline(balances: _balances),
              ),
            ],
            if (_holdings.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text(
                l.accountDetailTopHoldings,
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 8),
              ..._holdings.take(3).map(
                    (holding) => Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              holding.ticker?.isNotEmpty == true
                                  ? holding.ticker!
                                  : holding.securityName?.trim().isNotEmpty == true
                                      ? holding.securityName!
                                      : l.accountDetailHoldingFallback,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          Text(
                            MoneyMasker.mask(holding.amount,
                                hidden: hideAmounts),
                            style: Theme.of(context)
                                .textTheme
                                .bodyMedium
                                ?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                          ),
                        ],
                      ),
                    ),
                  ),
            ],
            if (_detailsUnavailable) ...[
              const SizedBox(height: 8),
              Text(
                l.accountDetailUnavailable,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colorScheme.error,
                    ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _DetailChip extends StatelessWidget {
  final String label;
  final IconData icon;

  const _DetailChip({
    required this.label,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: colorScheme.onSurfaceVariant),
          const SizedBox(width: 4),
          Text(
            label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
          ),
        ],
      ),
    );
  }
}

class _BalanceSparkline extends StatelessWidget {
  final List<AccountBalance> balances;

  const _BalanceSparkline({required this.balances});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final points = balances
        .where((balance) => balance.balanceCents != null)
        .toList()
        .reversed
        .toList();

    if (points.length < 2) {
      return const SizedBox.shrink();
    }

    return CustomPaint(
      painter: _BalanceSparklinePainter(
        values:
            points.map((balance) => balance.balanceCents!.toDouble()).toList(),
        color: colorScheme.primary,
      ),
      child: const SizedBox.expand(),
    );
  }
}

class _BalanceSparklinePainter extends CustomPainter {
  final List<double> values;
  final Color color;

  const _BalanceSparklinePainter({
    required this.values,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2) return;

    var minValue = values.first;
    var maxValue = values.first;
    for (final value in values) {
      if (value < minValue) minValue = value;
      if (value > maxValue) maxValue = value;
    }

    final range = maxValue - minValue;
    final path = Path();
    for (var index = 0; index < values.length; index++) {
      final x = size.width * (index / (values.length - 1));
      final normalized = range == 0 ? 0.5 : (values[index] - minValue) / range;
      final y = size.height - (normalized * size.height);

      if (index == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }

    final guidePaint = Paint()
      ..color = color.withValues(alpha: 0.12)
      ..strokeWidth = 1;
    canvas.drawLine(
      Offset(0, size.height / 2),
      Offset(size.width, size.height / 2),
      guidePaint,
    );

    final linePaint = Paint()
      ..color = color
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(path, linePaint);
  }

  @override
  bool shouldRepaint(covariant _BalanceSparklinePainter oldDelegate) {
    return !listEquals(oldDelegate.values, values) ||
        oldDelegate.color != color;
  }
}
