import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../models/offline_transaction.dart';
import '../models/transaction_split.dart';
import '../providers/auth_provider.dart';
import '../providers/categories_provider.dart';
import '../providers/privacy_provider.dart';
import '../providers/transaction_splits_provider.dart';
import '../providers/transactions_provider.dart';
import '../screens/transaction_split_screen.dart';
import '../theme/sure_colors.dart';
import '../theme/sure_spacing.dart';
import '../theme/sure_tokens.dart';
import '../utils/amount_parser.dart';
import '../utils/money_masker.dart';
import '../utils/split_math.dart';
import 'money_text.dart';
import 'sure_button.dart';
import 'sure_card.dart';

/// Split details for the transaction detail/edit screen, mirroring the web
/// transaction drawer:
/// - a split parent lists its children with "Edit split" and "Unsplit";
/// - a split child says it is part of a split and links to the same actions;
/// - any other synced transaction offers "Split transaction".
///
/// Splits need the server, so everything here is read-only (or hidden) while
/// offline. [onChanged] fires after a successful write with `true` when the
/// transaction this screen shows no longer exists (a child of a split that
/// was replaced or removed).
class TransactionSplitSection extends StatefulWidget {
  const TransactionSplitSection({
    super.key,
    required this.transaction,
    this.onChanged,
  });

  final OfflineTransaction transaction;
  final ValueChanged<bool>? onChanged;

  @override
  State<TransactionSplitSection> createState() =>
      _TransactionSplitSectionState();
}

class _TransactionSplitSectionState extends State<TransactionSplitSection> {
  bool _loaded = false;
  bool _working = false;

  /// Set while offline, so the lookup is retried once the device reconnects.
  bool _wasOffline = false;

  String? get _id => widget.transaction.id;

  bool get _isSynced =>
      _id != null && widget.transaction.syncStatus == SyncStatus.synced;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    if (!_isSynced || !mounted) return;
    final authProvider = Provider.of<AuthProvider>(context, listen: false);
    final splitsProvider = Provider.of<TransactionSplitsProvider>(
      context,
      listen: false,
    );
    final accessToken = await authProvider.getValidAccessToken();
    if (accessToken == null || !mounted) return;
    await splitsProvider.loadSplit(
      accessToken: accessToken,
      transactionId: _id!,
    );
    if (mounted) setState(() => _loaded = true);
  }

  String? get _locale => Localizations.maybeLocaleOf(context)?.toString();

  /// Editor target for a transaction that is not split yet. The list only has
  /// the display-formatted amount, so the magnitude comes from that and the
  /// sign from the classification; the server re-checks the exact sum.
  SplitEditorTarget? _targetForUnsplit() {
    final transaction = widget.transaction;
    try {
      final parsed = AmountParser.parse(transaction.amount);
      final magnitude =
          SplitMath.parseUnits(parsed.canonicalValue.replaceFirst('-', ''));
      if (magnitude == null) return null;
      return SplitEditorTarget(
        transactionId: _id!,
        accountId: transaction.accountId,
        name: transaction.name,
        date: transaction.date,
        currency: transaction.currency,
        categoryId: transaction.categoryId,
        amountUnits: transaction.isIncome ? -magnitude : magnitude,
      );
    } on FormatException {
      return null;
    }
  }

  SplitEditorTarget _targetForSplit(TransactionSplit split) {
    final transactions =
        Provider.of<TransactionsProvider>(context, listen: false)
            .offlineTransactions;
    OfflineTransaction? parent;
    for (final t in transactions) {
      if (t.id == split.transactionId) {
        parent = t;
        break;
      }
    }
    final isParent = split.transactionId == _id;
    final source = parent ?? (isParent ? widget.transaction : null);

    return SplitEditorTarget(
      transactionId: split.transactionId,
      accountId: widget.transaction.accountId,
      name: source?.name ?? widget.transaction.name,
      date: source?.date ?? widget.transaction.date,
      currency: split.currency.isNotEmpty
          ? split.currency
          : widget.transaction.currency,
      categoryId: source?.categoryId,
      amountUnits: split.amountUnits,
    );
  }

  Future<void> _openEditor({
    required SplitEditorTarget target,
    TransactionSplit? existing,
  }) async {
    final saved = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => TransactionSplitScreen(
          target: target,
          existing: existing,
        ),
      ),
    );
    if (saved == true && mounted) {
      // A replace destroys and recreates every child, including this one.
      widget.onChanged?.call(existing != null && existing.transactionId != _id);
    }
  }

  Future<void> _confirmUnsplit(TransactionSplit split) async {
    final l = AppLocalizations.of(context);
    final palette = SureColors.of(context).palette;
    final messenger = ScaffoldMessenger.of(context);
    final authProvider = Provider.of<AuthProvider>(context, listen: false);
    final splitsProvider = Provider.of<TransactionSplitsProvider>(
      context,
      listen: false,
    );
    final transactionsProvider = Provider.of<TransactionsProvider>(
      context,
      listen: false,
    );

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        final dl = AppLocalizations.of(dialogContext);
        return AlertDialog(
          title: Text(dl.splitUnsplitTitle),
          content: Text(dl.splitUnsplitConfirm),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(dl.commonCancel),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              style: TextButton.styleFrom(foregroundColor: palette.destructive),
              child: Text(dl.splitUnsplitButton),
            ),
          ],
        );
      },
    );
    if (confirmed != true || !mounted) return;

    setState(() => _working = true);
    final accessToken = await authProvider.getValidAccessToken();
    if (accessToken == null) {
      if (mounted) setState(() => _working = false);
      messenger.showSnackBar(
        SnackBar(
          content: Text(l.transactionEditSessionExpired),
          backgroundColor: palette.destructive,
        ),
      );
      return;
    }

    final result = await splitsProvider.unsplit(
      accessToken: accessToken,
      transactionId: split.transactionId,
    );
    if (!mounted) return;
    setState(() => _working = false);

    if (!result.success) {
      final message = result.error == TransactionSplitsProvider.offlineError
          ? l.splitEditorOffline
          : (result.error ?? l.splitUnsplitFailed);
      messenger.showSnackBar(
        SnackBar(content: Text(message), backgroundColor: palette.destructive),
      );
      return;
    }

    transactionsProvider.refreshAfterSplitChange(
      accessToken: accessToken,
      accountId: widget.transaction.accountId,
      removedChildIds: result.removedChildIds,
    );
    messenger.showSnackBar(
      SnackBar(
        content: Text(l.splitUnsplitSuccess),
        backgroundColor: palette.success,
      ),
    );
    widget.onChanged?.call(split.transactionId != _id);
  }

  String _childAmount(TransactionSplit split, TransactionSplitChild child,
      {required bool hidden}) {
    // Same direction as the parent reads as a plain amount; a part that goes
    // the other way gets a minus sign, matching the editor's convention.
    final sign = split.amountUnits.isNegative ? BigInt.from(-1) : BigInt.one;
    final decimals = SplitMath.inputDecimals(split.currency, split.amountUnits);
    return MoneyMasker.mask(
      SplitMath.formatMoney(
        child.amountUnits * sign,
        split.currency,
        decimals: decimals,
        locale: _locale,
      ),
      hidden: hidden,
    );
  }

  String _categoryLabel(TransactionSplitChild child) {
    final l = AppLocalizations.of(context);
    final id = child.categoryId;
    if (id == null) return child.categoryName ?? l.splitUncategorized;
    for (final category in context.watch<CategoriesProvider>().categories) {
      if (category.id == id) return category.displayName;
    }
    return child.categoryName ?? l.splitUncategorized;
  }

  @override
  Widget build(BuildContext context) {
    if (!_isSynced) return const SizedBox.shrink();

    final l = AppLocalizations.of(context);
    final splitsProvider = context.watch<TransactionSplitsProvider>();
    final hidden = context.watch<PrivacyProvider>().hidden;
    final isOnline = splitsProvider.isOnline;
    final split = splitsProvider.splitFor(_id!);
    final loading = splitsProvider.isLoading(_id!) || (!_loaded && isOnline);

    if (!isOnline) {
      _wasOffline = true;
    } else if (_wasOffline) {
      _wasOffline = false;
      if (_loaded && !splitsProvider.isSplitStatusKnown(_id!)) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _load());
      }
    }

    if (split == null) {
      if (!isOnline) return SplitNoticeBanner(text: l.splitOfflineNotice);
      if (loading) {
        return const Padding(
          padding: EdgeInsets.all(SureSpacing.xl),
          child: Center(child: CircularProgressIndicator()),
        );
      }
      if (splitsProvider.lastError != null &&
          !splitsProvider.isSplitStatusKnown(_id!)) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SplitNoticeBanner(text: l.splitLoadFailed),
            const SizedBox(height: SureSpacing.md),
            Align(
              alignment: Alignment.centerLeft,
              child: SureButton(
                key: const Key('split-retry'),
                label: l.commonTryAgain,
                variant: SureButtonVariant.outline,
                size: SureButtonSize.sm,
                leading: const Icon(Icons.refresh, size: 16),
                onPressed: _load,
              ),
            ),
          ],
        );
      }

      final target = _targetForUnsplit();
      return _SectionCard(
        title: l.splitTransactionButton,
        description: l.splitTransactionDescription,
        actions: [
          SureButton(
            key: const Key('split-start'),
            label: l.splitTransactionButton,
            variant: SureButtonVariant.outline,
            leading: const Icon(Icons.call_split, size: 18),
            onPressed: target == null || _working
                ? null
                : () => _openEditor(target: target),
          ),
        ],
      );
    }

    final isParent = split.transactionId == _id;
    final actions = [
      SureButton(
        key: const Key('split-edit'),
        label: l.splitEditButton,
        variant: SureButtonVariant.outline,
        size: SureButtonSize.sm,
        leading: const Icon(Icons.edit_outlined, size: 16),
        onPressed: isOnline && !_working
            ? () => _openEditor(
                  target: _targetForSplit(split),
                  existing: split,
                )
            : null,
      ),
      SureButton(
        key: const Key('split-unsplit'),
        label: l.splitUnsplitButton,
        variant: SureButtonVariant.ghost,
        size: SureButtonSize.sm,
        leading: const Icon(Icons.undo, size: 16),
        loading: _working,
        onPressed: isOnline && !_working ? () => _confirmUnsplit(split) : null,
      ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!isOnline) ...[
          SplitNoticeBanner(text: l.splitOfflineNotice),
          const SizedBox(height: SureSpacing.lg),
        ],
        _SectionCard(
          title: isParent ? l.splitSectionTitle : l.splitChildTitle,
          description:
              isParent ? l.splitSectionDescription : l.splitChildDescription,
          actions: actions,
          children: [
            for (final child in split.children)
              _ChildRow(
                name: child.name,
                category: _categoryLabel(child),
                amount: _childAmount(split, child, hidden: hidden),
                highlighted: child.id == _id,
              ),
          ],
        ),
      ],
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.title,
    required this.description,
    required this.actions,
    this.children = const [],
  });

  final String title;
  final String description;
  final List<Widget> actions;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = SureColors.of(context).palette;

    return SureCard(
      key: const Key('transaction-split-section'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.call_split, size: 18, color: palette.textSecondary),
              const SizedBox(width: SureSpacing.md),
              Expanded(
                child: Text(
                  title,
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: palette.textPrimary,
                    fontWeight: SureTokens.weightSemibold,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: SureSpacing.sm),
          Text(
            description,
            style: theme.textTheme.bodySmall?.copyWith(
              color: palette.textSecondary,
            ),
          ),
          if (children.isNotEmpty) ...[
            const SizedBox(height: SureSpacing.lg),
            for (final child in children) ...[
              child,
              const SizedBox(height: SureSpacing.md),
            ],
          ] else
            const SizedBox(height: SureSpacing.lg),
          Wrap(
            spacing: SureSpacing.md,
            runSpacing: SureSpacing.md,
            children: actions,
          ),
        ],
      ),
    );
  }
}

class _ChildRow extends StatelessWidget {
  const _ChildRow({
    required this.name,
    required this.category,
    required this.amount,
    this.highlighted = false,
  });

  final String name;
  final String category;
  final String amount;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = SureColors.of(context).palette;

    return Container(
      padding: const EdgeInsets.all(SureSpacing.lg),
      decoration: BoxDecoration(
        color: highlighted ? palette.containerInset : null,
        borderRadius: BorderRadius.circular(SureTokens.radiusMd),
        border: Border.all(color: palette.borderSecondary),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: palette.textPrimary,
                    fontWeight: SureTokens.weightMedium,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  category,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: palette.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: SureSpacing.lg),
          Text(
            amount,
            style: SureMoney.tabular(
              theme.textTheme.bodyMedium?.copyWith(
                color: palette.textPrimary,
                fontWeight: SureTokens.weightMedium,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Small warning-toned banner used by the split UI (e.g. "you're offline").
class SplitNoticeBanner extends StatelessWidget {
  const SplitNoticeBanner({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final palette = SureColors.of(context).palette;
    return Container(
      padding: const EdgeInsets.all(SureSpacing.lg),
      decoration: BoxDecoration(
        color: palette.warning.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(SureTokens.radiusLg),
        border: Border.all(color: palette.warning.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          Icon(Icons.cloud_off, size: 18, color: palette.warning),
          const SizedBox(width: SureSpacing.md),
          Expanded(
            child: Text(
              text,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: palette.textPrimary),
            ),
          ),
        ],
      ),
    );
  }
}

/// "Split" pill shown on split parents in the transaction list, mirroring the
/// web `DS::Pill` with the `split` icon.
class SplitBadge extends StatelessWidget {
  const SplitBadge({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final palette = SureColors.of(context).palette;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: SureSpacing.sm,
        vertical: 2,
      ),
      decoration: BoxDecoration(
        color: palette.containerInset,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: palette.borderSecondary),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.call_split, size: 12, color: palette.textSecondary),
          const SizedBox(width: 2),
          Text(
            label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: palette.textSecondary,
                  fontWeight: SureTokens.weightMedium,
                ),
          ),
        ],
      ),
    );
  }
}
