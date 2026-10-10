import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import '../models/monthly_spending.dart';
import '../providers/privacy_provider.dart';
import '../services/monthly_spending_service.dart';
import '../theme/sure_colors.dart';
import '../theme/sure_spacing.dart';
import '../utils/money_masker.dart';
import 'sure_button.dart';
import 'sure_card.dart';
import 'sure_text_field.dart';

class MonthlySpendingCard extends StatefulWidget {
  const MonthlySpendingCard(
      {super.key, required this.loader, this.revision = 0});
  final MonthlySpendingLoader loader;
  final int revision;

  @override
  State<MonthlySpendingCard> createState() => _MonthlySpendingCardState();
}

class _MonthlySpendingCardState extends State<MonthlySpendingCard> {
  MonthlySpendingSelection _selection = const MonthlySpendingSelection();
  MonthlySpendingResult? _result;
  bool _loading = true;
  bool _hasPreviewAccess = false;
  int _request = 0;
  String? _selectedMonth;
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant MonthlySpendingCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.revision != widget.revision) _load();
  }

  @override
  void dispose() {
    _request++;
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final request = ++_request;
    setState(() {
      _loading = true;
    });
    MonthlySpendingResult result;
    try {
      result = await widget.loader(_selection);
    } catch (_) {
      result = const MonthlySpendingResult(MonthlySpendingStatus.error);
    }
    if (!mounted || request != _request) return;
    setState(() {
      _result = result;
      if (result.status == MonthlySpendingStatus.ready) {
        _hasPreviewAccess = true;
      } else if (result.status == MonthlySpendingStatus.unavailable ||
          result.status == MonthlySpendingStatus.unauthorized) {
        _hasPreviewAccess = false;
      }
      _loading = false;
      final months = result.data?.months ?? [];
      if (!months.any((month) => month.month == _selectedMonth)) {
        _selectedMonth = months.isEmpty ? null : months.last.month;
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  String _monthLabel(String month) =>
      DateFormat.yMMM(Localizations.localeOf(context).toString())
          .format(DateTime.parse(month));

  String _money(double amount, String currency) {
    final formatted = NumberFormat.simpleCurrency(
            locale: Localizations.localeOf(context).toString(), name: currency)
        .format(amount);
    return MoneyMasker.mask(formatted,
        hidden: context.watch<PrivacyProvider>().hidden);
  }

  Future<void> _filters(MonthlySpendingData data) async {
    final selection = await showModalBottomSheet<MonthlySpendingSelection>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _SpendingFilters(data: data),
    );
    if (!mounted || selection == null) return;
    _selection = selection;
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final palette = SureColors.of(context).palette;
    final data = _result?.data;
    // Do not flash a preview surface before the server confirms personal
    // access. Home's pull-to-refresh can retry an initial unavailable request.
    if (!_hasPreviewAccess) return const SizedBox.shrink();
    if (!_loading &&
        (_result?.status == MonthlySpendingStatus.unavailable ||
            _result?.status == MonthlySpendingStatus.unauthorized)) {
      return const SizedBox.shrink();
    }
    return SureCard(
      margin: const EdgeInsets.all(SureSpacing.xl),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(l.monthlySpendingTitle,
            style: Theme.of(context).textTheme.titleMedium),
        Text(l.monthlySpendingPreview,
            style: TextStyle(color: palette.textSecondary)),
        const SizedBox(height: SureSpacing.md),
        if (_loading)
          const Center(child: CircularProgressIndicator())
        else if (data == null) ...[
          Text(_result?.status == MonthlySpendingStatus.invalidSelection
              ? l.monthlySpendingInvalid
              : l.monthlySpendingError),
          Wrap(spacing: SureSpacing.md, children: [
            SureButton(label: l.commonTryAgain, onPressed: _load),
            SureButton(
                label: l.monthlySpendingReset,
                variant: SureButtonVariant.ghost,
                onPressed: () {
                  _selection = const MonthlySpendingSelection();
                  _load();
                }),
          ]),
        ] else ...[
          Wrap(spacing: SureSpacing.md, runSpacing: SureSpacing.md, children: [
            SureButton(
                label: l.monthlySpendingFilters,
                variant: SureButtonVariant.outline,
                onPressed: () => _filters(data)),
            SureButton(
                label: l.monthlySpendingReset,
                variant: SureButtonVariant.ghost,
                onPressed: () {
                  _selection = const MonthlySpendingSelection();
                  _load();
                }),
          ]),
          const SizedBox(height: SureSpacing.md),
          Text('${_monthLabel(data.from)} – ${_monthLabel(data.to)}'),
          Text(
              l.monthlySpendingScope(
                  data.accountIds.length, data.categoryIds.length),
              style: TextStyle(color: palette.textSecondary)),
          Text(l.monthlySpendingBasis,
              style: TextStyle(color: palette.textSecondary)),
          if (data.missingExchangeRates > 0)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: SureSpacing.md),
              child: Text(l.monthlySpendingFx,
                  style: TextStyle(color: palette.warning)),
            ),
          const SizedBox(height: SureSpacing.md),
          if (data.emptySelection)
            Text(l.monthlySpendingEmptySelection)
          else if (data.months.every((month) => month.total == 0))
            Text(l.monthlySpendingEmpty)
          else ...[
            if (!context.watch<PrivacyProvider>().hidden)
              _chart(data)
            else
              Text(l.monthlySpendingChartHidden),
            Text(l.monthlySpendingHint,
                style: TextStyle(color: palette.textSecondary)),
            const SizedBox(height: SureSpacing.md),
            _details(data),
          ],
        ],
      ]),
    );
  }

  Widget _chart(MonthlySpendingData data) {
    final palette = SureColors.of(context).palette;
    final maximum = data.months.map((month) => month.total).reduce(math.max);
    final categories = {
      for (final category in data.categories) category.id: category
    };
    final textScaler = MediaQuery.textScalerOf(context);
    return SizedBox(
      height: 180 + textScaler.scale(100),
      child: ListView.separated(
        controller: _scroll,
        scrollDirection: Axis.horizontal,
        itemCount: data.months.length,
        separatorBuilder: (_, __) => const SizedBox(width: SureSpacing.md),
        itemBuilder: (context, index) {
          final month = data.months[index];
          final totalText = _money(month.total, data.currency);
          final totalStyle = Theme.of(context).textTheme.bodySmall;
          final totalPainter = TextPainter(
            text: TextSpan(text: totalText, style: totalStyle),
            textDirection: Directionality.of(context),
            textScaler: textScaler,
          )..layout();
          final barWidth =
              math.max(textScaler.scale(72), totalPainter.width + 16);
          final graphHeight = 180 + totalPainter.height + SureSpacing.sm;
          totalPainter.dispose();
          final label =
              '${_monthLabel(month.month)}, ${_money(month.total, data.currency)}${month.partial ? ', ${AppLocalizations.of(context).monthlySpendingPartial}' : ''}';
          return Semantics(
            button: true,
            selected: month.month == _selectedMonth,
            label: label,
            child: SizedBox(
              width: barWidth,
              child: InkWell(
                onTap: () => setState(() {
                  _selectedMonth = month.month;
                }),
                child: ExcludeSemantics(
                  child: Column(children: [
                    SizedBox(
                      height: graphHeight,
                      child: Container(
                        decoration: BoxDecoration(
                            border: Border(
                                bottom:
                                    BorderSide(color: palette.borderPrimary))),
                        child: Column(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              Text(totalText, style: totalStyle, maxLines: 1),
                              const SizedBox(height: SureSpacing.sm),
                              for (final entry
                                  in month.amounts.entries.toList().reversed)
                                Container(
                                    width: 48,
                                    height: 176 * entry.value / maximum,
                                    color: _categoryColor(
                                        categories[entry.key]?.color,
                                        palette.textSubdued)),
                            ]),
                      ),
                    ),
                    Text(
                        '${_monthLabel(month.month)}${month.partial ? '*' : ''}',
                        textAlign: TextAlign.center),
                  ]),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Color _categoryColor(String? hex, Color fallback) {
    if (hex == null || !RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(hex)) {
      return fallback;
    }
    return Color(int.parse('FF${hex.substring(1)}', radix: 16));
  }

  Widget _details(MonthlySpendingData data) {
    final l = AppLocalizations.of(context);
    final palette = SureColors.of(context).palette;
    final categories = {
      for (final category in data.categories) category.id: category
    };
    final month = data.months.firstWhere(
        (month) => month.month == _selectedMonth,
        orElse: () => data.months.last);
    final entries = month.amounts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      DropdownButtonFormField<String>(
        value: month.month,
        isExpanded: true,
        decoration: InputDecoration(labelText: l.monthlySpendingDetails),
        items: data.months
            .map((month) => DropdownMenuItem(
                value: month.month, child: Text(_monthLabel(month.month))))
            .toList(),
        onChanged: (value) => setState(() {
          _selectedMonth = value;
        }),
      ),
      Text(_money(month.total, data.currency),
          style: Theme.of(context).textTheme.titleMedium),
      if (month.partial) Text(l.monthlySpendingPartial),
      if (month.missingExchangeRates > 0) Text(l.monthlySpendingFx),
      for (final entry in entries)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: SureSpacing.sm),
          child: Row(children: [
            ExcludeSemantics(
              child: Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _categoryColor(
                      categories[entry.key]?.color, palette.textSubdued),
                ),
              ),
            ),
            const SizedBox(width: SureSpacing.sm),
            Expanded(child: Text(categories[entry.key]?.name ?? entry.key)),
            const SizedBox(width: SureSpacing.md),
            Text(_money(entry.value, data.currency)),
          ]),
        ),
      if (entries.isEmpty) Text(l.monthlySpendingEmpty),
    ]);
  }
}

class _SpendingFilters extends StatefulWidget {
  const _SpendingFilters({required this.data});
  final MonthlySpendingData data;
  @override
  State<_SpendingFilters> createState() => _SpendingFiltersState();
}

class _SpendingFiltersState extends State<_SpendingFilters> {
  late String _from;
  late String _to;
  late Set<String> _accounts;
  late Set<String> _categories;

  @override
  void initState() {
    super.initState();
    _from = widget.data.from;
    _to = widget.data.to;
    _accounts = widget.data.accountIds.toSet();
    _categories = widget.data.categoryIds.toSet();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final asOf = widget.data.asOf;
    final months = {
      _from,
      _to,
      ...List.generate(
          36,
          (offset) => DateTime(asOf.year, asOf.month - offset)
              .toIso8601String()
              .substring(0, 10))
    }.toList()
      ..sort();
    Widget picker(String label, String value, ValueChanged<String> change) =>
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          DropdownButtonFormField<String>(
            value: value,
            isExpanded: true,
            decoration: InputDecoration(labelText: label),
            items: months
                .map((month) => DropdownMenuItem(
                    value: month,
                    child: Text(DateFormat.yMMM(
                            Localizations.localeOf(context).toString())
                        .format(DateTime.parse(month)))))
                .toList(),
            onChanged: (value) {
              if (value != null) setState(() => change(value));
            },
          ),
          SureButton(
              label: l.monthlySpendingChooseMonth,
              variant: SureButtonVariant.ghost,
              onPressed: () async {
                final date = await showDatePicker(
                    context: context,
                    initialDate: DateTime.parse(value),
                    firstDate: DateTime(1),
                    lastDate: asOf,
                    initialDatePickerMode: DatePickerMode.year,
                    helpText: label);
                if (mounted && date != null) {
                  setState(() => change(DateTime(date.year, date.month)
                      .toIso8601String()
                      .substring(0, 10)));
                }
              }),
        ]);
    final fromMonth = DateTime.parse(_from);
    final toMonth = DateTime.parse(_to);
    final monthCount = (toMonth.year - fromMonth.year) * 12 +
        toMonth.month -
        fromMonth.month +
        1;
    final validPeriod = monthCount >= 1 && monthCount <= 36;
    void setPeriod(DateTime from, DateTime to) => setState(() {
          _from = from.toIso8601String().substring(0, 10);
          _to = to.toIso8601String().substring(0, 10);
        });
    return SafeArea(
        child: Padding(
      padding: EdgeInsets.fromLTRB(
          SureSpacing.xl,
          SureSpacing.xl,
          SureSpacing.xl,
          MediaQuery.viewInsetsOf(context).bottom + SureSpacing.xl),
      child: SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.8,
          child: Column(children: [
            Expanded(
                child: ListView(children: [
              Text(l.monthlySpendingFilters,
                  style: Theme.of(context).textTheme.titleLarge),
              Wrap(
                  spacing: SureSpacing.md,
                  runSpacing: SureSpacing.md,
                  children: [
                    SureButton(
                        label: l.monthlySpendingLastTwelve,
                        variant: SureButtonVariant.ghost,
                        onPressed: () => setPeriod(
                            DateTime(asOf.year, asOf.month - 11),
                            DateTime(asOf.year, asOf.month))),
                    SureButton(
                        label: l.monthlySpendingThisYear,
                        variant: SureButtonVariant.ghost,
                        onPressed: () => setPeriod(DateTime(asOf.year),
                            DateTime(asOf.year, asOf.month))),
                    SureButton(
                        label: l.monthlySpendingPreviousYear,
                        variant: SureButtonVariant.ghost,
                        onPressed: () => setPeriod(DateTime(asOf.year - 1),
                            DateTime(asOf.year - 1, 12))),
                  ]),
              picker(l.monthlySpendingFrom, _from, (value) => _from = value),
              picker(l.monthlySpendingTo, _to, (value) => _to = value),
              _SpendingChecklist(
                  title: l.monthlySpendingAccounts,
                  options: widget.data.accounts,
                  selected: _accounts),
              _SpendingChecklist(
                  title: l.monthlySpendingCategories,
                  options: widget.data.categories,
                  selected: _categories),
            ])),
            SureButton(
                label: l.monthlySpendingApply,
                fullWidth: true,
                onPressed: !validPeriod
                    ? null
                    : () => Navigator.pop(
                        context,
                        MonthlySpendingSelection(
                            from: _from,
                            to: _to,
                            accountIds: _accounts.toList(),
                            categoryIds: _categories.toList()))),
            if (!validPeriod) Text(l.monthlySpendingInvalid),
          ])),
    ));
  }
}

class _SpendingChecklist extends StatefulWidget {
  const _SpendingChecklist(
      {required this.title, required this.options, required this.selected});
  final String title;
  final List<SpendingOption> options;
  final Set<String> selected;
  @override
  State<_SpendingChecklist> createState() => _SpendingChecklistState();
}

class _SpendingChecklistState extends State<_SpendingChecklist> {
  String _search = '';
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final options = widget.options
        .where((option) => option.name.toLowerCase().contains(_search))
        .toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const SizedBox(height: SureSpacing.xl),
      SureTextField(
          label: widget.title,
          hint: l.monthlySpendingSearch,
          onChanged: (value) => setState(() => _search = value.toLowerCase())),
      Wrap(spacing: SureSpacing.md, children: [
        SureButton(
            label: l.monthlySpendingAll,
            variant: SureButtonVariant.ghost,
            onPressed: () => setState(() => widget.selected
                .addAll(widget.options.map((option) => option.id)))),
        SureButton(
            label: l.monthlySpendingNone,
            variant: SureButtonVariant.ghost,
            onPressed: () => setState(() => widget.selected.clear())),
      ]),
      for (final option in options)
        CheckboxListTile(
          title: Text(option.name),
          value: widget.selected.contains(option.id),
          controlAffinity: ListTileControlAffinity.leading,
          onChanged: (value) => setState(() {
            if (value == true) {
              widget.selected.add(option.id);
            } else {
              widget.selected.remove(option.id);
            }
          }),
        ),
      if (options.isEmpty) Text(l.monthlySpendingNoResults),
    ]);
  }
}
