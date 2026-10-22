import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../models/category.dart' as models;
import '../models/transaction_split.dart';
import '../providers/auth_provider.dart';
import '../providers/categories_provider.dart';
import '../providers/privacy_provider.dart';
import '../providers/transaction_splits_provider.dart';
import '../providers/transactions_provider.dart';
import '../theme/sure_colors.dart';
import '../theme/sure_spacing.dart';
import '../theme/sure_tokens.dart';
import '../utils/money_masker.dart';
import '../utils/split_math.dart';
import '../widgets/money_text.dart';
import '../widgets/sure_button.dart';
import '../widgets/sure_card.dart';
import '../widgets/sure_text_field.dart';
import '../widgets/transaction_split_section.dart' show SplitNoticeBanner;

/// The transaction being split, reduced to what the editor needs.
class SplitEditorTarget {
  /// Server id of the split parent (or the transaction about to be split).
  final String transactionId;
  final String accountId;
  final String name;
  final String date;
  final String currency;
  final String? categoryId;

  /// Exact parent amount in [SplitMath.scale] units, API sign convention
  /// (expenses positive, income negative).
  final BigInt amountUnits;

  const SplitEditorTarget({
    required this.transactionId,
    required this.accountId,
    required this.name,
    required this.date,
    required this.currency,
    required this.amountUnits,
    this.categoryId,
  });

  /// +1 for expenses (positive stored amounts), -1 for income.
  BigInt get sign => amountUnits.isNegative ? BigInt.from(-1) : BigInt.one;

  /// The total the rows must add up to, as the user sees it (always >= 0).
  BigInt get totalMagnitude => amountUnits.abs();
}

class _SplitRow {
  _SplitRow({String name = '', String amount = '', this.categoryId})
      : nameController = TextEditingController(text: name),
        amountController = TextEditingController(text: amount);

  final Key key = UniqueKey();
  final TextEditingController nameController;
  final TextEditingController amountController;
  String? categoryId;

  /// Carried over from an existing child so a replace does not silently
  /// re-include an entry the user excluded on the web.
  bool excluded = false;

  void dispose() {
    nameController.dispose();
    amountController.dispose();
  }
}

/// Create or edit a transaction split: one row per child with a name, amount
/// and category, a live "remaining" indicator, and a save that is only enabled
/// once the rows add up exactly to the original amount. Mirrors the web
/// split editor (`app/views/splits/new|edit.html.erb`).
///
/// Row amounts are entered as magnitudes in the same direction as the original
/// transaction; a minus sign marks a part that goes the other way.
class TransactionSplitScreen extends StatefulWidget {
  final SplitEditorTarget target;

  /// The current split when editing; null when creating a new one.
  final TransactionSplit? existing;

  const TransactionSplitScreen({
    super.key,
    required this.target,
    this.existing,
  });

  @override
  State<TransactionSplitScreen> createState() => _TransactionSplitScreenState();
}

class _TransactionSplitScreenState extends State<TransactionSplitScreen> {
  static const _maxNameLength = 255;

  final _formKey = GlobalKey<FormState>();
  final List<_SplitRow> _rows = [];
  bool _isSaving = false;

  SplitEditorTarget get _target => widget.target;
  bool get _isEditing => widget.existing != null;
  int get _decimals => SplitMath.inputDecimals(
        _target.currency,
        _target.amountUnits,
        childUnits: widget.existing?.children.map((c) => c.amountUnits) ??
            const [],
      );

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    if (existing != null && existing.children.isNotEmpty) {
      for (final child in existing.children) {
        final magnitude = child.amountUnits * _target.sign;
        _rows.add(
          _SplitRow(
            name: child.name,
            amount: SplitMath.toDecimalString(magnitude, decimals: _decimals),
            categoryId: child.categoryId,
          )..excluded = child.excluded,
        );
      }
    } else {
      _rows
        ..add(_SplitRow(name: _target.name, categoryId: _target.categoryId))
        ..add(_SplitRow());
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadCategories());
  }

  @override
  void dispose() {
    for (final row in _rows) {
      row.dispose();
    }
    super.dispose();
  }

  Future<void> _loadCategories() async {
    final authProvider = Provider.of<AuthProvider>(context, listen: false);
    final categoriesProvider = Provider.of<CategoriesProvider>(
      context,
      listen: false,
    );
    try {
      final accessToken = await authProvider.getValidAccessToken();
      if (accessToken == null || !mounted) return;
      await categoriesProvider.fetchCategories(accessToken: accessToken);
    } catch (_) {
      // CategoriesProvider exposes its own error state.
    }
  }

  String? get _locale => Localizations.maybeLocaleOf(context)?.toString();

  BigInt get _remaining => SplitMath.remaining(
        _target.totalMagnitude,
        _rows.map((row) => row.amountController.text),
        locale: _locale,
      );

  bool get _rowsValid => _rows.every(
        (row) =>
            row.nameController.text.trim().isNotEmpty &&
            SplitMath.validateAmount(
                  row.amountController.text,
                  decimals: _decimals,
                  locale: _locale,
                ) ==
                null,
      );

  void _addRow() {
    setState(() => _rows.add(_SplitRow()));
  }

  void _removeRow(_SplitRow row) {
    if (_rows.length <= 1) return;
    setState(() => _rows.remove(row));
    row.dispose();
  }

  String? _validateName(String? value) {
    final l = AppLocalizations.of(context);
    final text = value?.trim() ?? '';
    if (text.isEmpty) return l.splitEditorNameRequired;
    if (text.length > _maxNameLength) {
      return l.transactionEditNameMaxLength(_maxNameLength);
    }
    return null;
  }

  String? _validateAmount(String? value) {
    final l = AppLocalizations.of(context);
    switch (SplitMath.validateAmount(
      value ?? '',
      decimals: _decimals,
      locale: _locale,
    )) {
      case SplitAmountError.required:
        return l.splitEditorAmountRequired;
      case SplitAmountError.invalid:
        return l.splitEditorAmountInvalid;
      case SplitAmountError.zero:
        return l.splitEditorAmountZero;
      case SplitAmountError.tooPrecise:
        return l.splitEditorAmountTooPrecise(_decimals);
      case null:
        return null;
    }
  }

  Future<void> _save() async {
    final l = AppLocalizations.of(context);
    if (!_formKey.currentState!.validate() ||
        _remaining != BigInt.zero ||
        _isSaving) {
      return;
    }

    final authProvider = Provider.of<AuthProvider>(context, listen: false);
    final splitsProvider = Provider.of<TransactionSplitsProvider>(
      context,
      listen: false,
    );
    final transactionsProvider = Provider.of<TransactionsProvider>(
      context,
      listen: false,
    );
    final messenger = ScaffoldMessenger.of(context);
    final palette = SureColors.of(context).palette;

    final rows = _rows.map((row) {
      final units =
          SplitMath.parseUserInput(row.amountController.text, locale: _locale)!;
      return SplitRowInput(
        name: row.nameController.text.trim(),
        amount: SplitMath.toDecimalString(units * _target.sign),
        categoryId: row.categoryId,
        excluded: row.excluded,
      );
    }).toList();

    setState(() => _isSaving = true);

    final accessToken = await authProvider.getValidAccessToken();
    if (accessToken == null) {
      if (!mounted) return;
      setState(() => _isSaving = false);
      messenger.showSnackBar(
        SnackBar(
          content: Text(l.transactionEditSessionExpired),
          backgroundColor: palette.destructive,
        ),
      );
      return;
    }

    final result = await splitsProvider.saveSplit(
      accessToken: accessToken,
      transactionId: _target.transactionId,
      rows: rows,
      replace: _isEditing,
    );

    if (!mounted) return;

    if (!result.success) {
      setState(() => _isSaving = false);
      final message = result.error == TransactionSplitsProvider.offlineError
          ? l.splitEditorOffline
          : (result.error ?? l.splitEditorSaveFailed);
      messenger.showSnackBar(
        SnackBar(content: Text(message), backgroundColor: palette.destructive),
      );
      return;
    }

    // The list reload runs in the background; the editor can close now.
    transactionsProvider.refreshAfterSplitChange(
      accessToken: accessToken,
      accountId: _target.accountId,
      removedChildIds: result.removedChildIds,
    );

    messenger.showSnackBar(
      SnackBar(
        content: Text(_isEditing ? l.splitEditorUpdated : l.splitEditorSaved),
        backgroundColor: palette.success,
      ),
    );
    Navigator.pop(context, true);
  }

  List<DropdownMenuItem<String?>> _categoryItems(
    List<models.Category> categories,
    _SplitRow row,
  ) {
    final l = AppLocalizations.of(context);
    final items = <DropdownMenuItem<String?>>[
      DropdownMenuItem<String?>(
        value: null,
        child: Text(l.splitUncategorized),
      ),
    ];

    final hasCurrent = row.categoryId == null ||
        categories.any((category) => category.id == row.categoryId);
    if (!hasCurrent) {
      items.add(
        DropdownMenuItem<String?>(
          value: row.categoryId,
          child: Text(l.transactionEditCurrentCategory),
        ),
      );
    }

    items.addAll(
      categories.map(
        (category) => DropdownMenuItem<String?>(
          value: category.id,
          child: Text(category.displayName, overflow: TextOverflow.ellipsis),
        ),
      ),
    );
    return items;
  }

  String _money(BigInt units, {required bool hidden}) {
    return MoneyMasker.mask(
      SplitMath.formatMoney(
        units,
        _target.currency,
        decimals: _decimals,
        locale: _locale,
      ),
      hidden: hidden,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final palette = SureColors.of(context).palette;
    final hidden = context.watch<PrivacyProvider>().hidden;
    final isOnline = context.watch<TransactionSplitsProvider>().isOnline;

    final remaining = _remaining;
    final balanced = remaining == BigInt.zero;
    final canSave = isOnline && !_isSaving && balanced && _rowsValid;

    return Scaffold(
      appBar: AppBar(
        title:
            Text(_isEditing ? l.splitEditorEditTitle : l.splitEditorNewTitle),
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(SureSpacing.xl),
          children: [
            if (!isOnline) ...[
              SplitNoticeBanner(text: l.splitEditorOffline),
              const SizedBox(height: SureSpacing.lg),
            ],
            SureCard(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _target.name,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: SureTokens.weightSemibold,
                            color: palette.textPrimary,
                          ),
                        ),
                        const SizedBox(height: SureSpacing.xs),
                        Text(
                          _target.date,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: palette.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: SureSpacing.lg),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        l.splitEditorOriginalAmount,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: palette.textSecondary,
                        ),
                      ),
                      const SizedBox(height: SureSpacing.xs),
                      Text(
                        _money(_target.totalMagnitude, hidden: hidden),
                        key: const Key('split-original-amount'),
                        style: SureMoney.tabular(
                          theme.textTheme.titleMedium?.copyWith(
                            fontWeight: SureTokens.weightSemibold,
                            color: palette.textPrimary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: SureSpacing.lg),
            Text(
              l.splitEditorAmountHelper,
              style: theme.textTheme.bodySmall?.copyWith(
                color: palette.textSecondary,
              ),
            ),
            const SizedBox(height: SureSpacing.lg),
            for (var i = 0; i < _rows.length; i++) ...[
              _buildRow(i, _rows[i], hidden: hidden),
              const SizedBox(height: SureSpacing.lg),
            ],
            SureButton(
              key: const Key('split-add-row'),
              label: l.splitEditorAddRow,
              variant: SureButtonVariant.outline,
              leading: const Icon(Icons.add, size: 18),
              fullWidth: true,
              onPressed: _isSaving ? null : _addRow,
            ),
            const SizedBox(height: SureSpacing.lg),
            _RemainingIndicator(
              label: l.splitEditorRemaining,
              amount: _money(remaining, hidden: hidden),
              balanced: balanced,
              message: balanced ? null : l.splitEditorAmountsMustMatch,
            ),
            const SizedBox(height: SureSpacing.xxxl),
            SureButton(
              key: const Key('split-save'),
              label:
                  _isEditing ? l.splitEditorSubmitEdit : l.splitEditorSubmitNew,
              fullWidth: true,
              size: SureButtonSize.lg,
              loading: _isSaving,
              onPressed: canSave ? _save : null,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRow(int index, _SplitRow row, {required bool hidden}) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final palette = SureColors.of(context).palette;

    return SureCard(
      key: row.key,
      elevated: false,
      padding: const EdgeInsets.all(SureSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  l.splitEditorRowLabel(index + 1),
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: palette.textSecondary,
                    fontWeight: SureTokens.weightMedium,
                  ),
                ),
              ),
              if (_rows.length > 1)
                IconButton(
                  key: Key('split-remove-row-$index'),
                  icon: const Icon(Icons.close, size: 18),
                  tooltip: l.splitEditorRemoveRow,
                  visualDensity: VisualDensity.compact,
                  onPressed: _isSaving ? null : () => _removeRow(row),
                ),
            ],
          ),
          const SizedBox(height: SureSpacing.md),
          SureTextField(
            key: Key('split-name-$index'),
            controller: row.nameController,
            label: l.splitEditorNameLabel,
            hint: l.splitEditorNamePlaceholder,
            enabled: !_isSaving,
            validator: _validateName,
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: SureSpacing.md),
          SureTextField(
            key: Key('split-amount-$index'),
            controller: row.amountController,
            label: l.splitEditorAmountLabel,
            hint: SplitMath.toDecimalString(BigInt.zero, decimals: _decimals),
            enabled: !_isSaving,
            obscureText: hidden,
            keyboardType: const TextInputType.numberWithOptions(
              decimal: true,
              signed: true,
            ),
            validator: _validateAmount,
            autovalidateMode: AutovalidateMode.onUserInteraction,
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: SureSpacing.md),
          Consumer<CategoriesProvider>(
            builder: (context, categoriesProvider, _) {
              return DropdownButtonFormField<String?>(
                key: Key('split-category-$index'),
                value: row.categoryId,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: l.splitEditorCategoryLabel,
                ),
                items: _categoryItems(categoriesProvider.categories, row),
                onChanged: _isSaving
                    ? null
                    : (value) => setState(() => row.categoryId = value),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _RemainingIndicator extends StatelessWidget {
  const _RemainingIndicator({
    required this.label,
    required this.amount,
    required this.balanced,
    this.message,
  });

  final String label;
  final String amount;
  final bool balanced;
  final String? message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = SureColors.of(context).palette;
    final tone = balanced ? palette.success : palette.destructive;

    return Container(
      key: const Key('split-remaining'),
      padding: const EdgeInsets.all(SureSpacing.lg),
      decoration: BoxDecoration(
        color: tone.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(SureTokens.radiusLg),
        border: Border.all(color: tone.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: palette.textSecondary,
                    fontWeight: SureTokens.weightMedium,
                  ),
                ),
              ),
              Text(
                amount,
                key: const Key('split-remaining-amount'),
                style: SureMoney.tabular(
                  theme.textTheme.bodyMedium?.copyWith(
                    color: tone,
                    fontWeight: SureTokens.weightSemibold,
                  ),
                ),
              ),
            ],
          ),
          if (message != null) ...[
            const SizedBox(height: SureSpacing.sm),
            Text(
              message!,
              style: theme.textTheme.bodySmall?.copyWith(color: tone),
            ),
          ],
        ],
      ),
    );
  }
}
