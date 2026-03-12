import 'package:flutter/material.dart';

class IntroScreenPlatform extends StatelessWidget {
  const IntroScreenPlatform({super.key, this.onStartChat});

  final VoidCallback? onStartChat;

  @override
  Widget build(BuildContext context) {
    const summary = _CashflowSummary(
      totalIncome: 7000.0,
      totalSpending: 5512.5,
      surplus: 1487.5,
      currency: 'KSh',
    );
    const incomeSources = <_InsightLine>[
      _InsightLine(
        label: 'Side Hustle',
        amount: 5500.0,
        percentage: 78.6,
        color: Color(0xFF6AD28A),
      ),
      _InsightLine(
        label: 'Loan',
        amount: 1500.0,
        percentage: 21.4,
        color: Color(0xFF6172F3),
      ),
    ];
    const spending = <_InsightLine>[
      _InsightLine(
        label: 'Family Support',
        amount: 1100.0,
        percentage: 20.0,
        color: Color(0xFF6172F3),
      ),
      _InsightLine(
        label: 'Transport',
        amount: 800.0,
        percentage: 14.5,
        color: Color(0xFF6172F3),
      ),
      _InsightLine(
        label: 'Groceries',
        amount: 700.0,
        percentage: 12.7,
        color: Color(0xFF6172F3),
      ),
      _InsightLine(
        label: 'Matatu & Boda',
        amount: 556.0,
        percentage: 10.1,
        color: Color(0xFF6172F3),
      ),
      _InsightLine(
        label: 'Airtime',
        amount: 350.0,
        percentage: 6.3,
        color: Color(0xFF6172F3),
      ),
      _InsightLine(
        label: 'Eating Out',
        amount: 350.0,
        percentage: 6.3,
        color: Color(0xFF6172F3),
      ),
      _InsightLine(
        label: 'Clothing',
        amount: 200.0,
        percentage: 3.6,
        color: Color(0xFF6172F3),
      ),
      _InsightLine(
        label: 'Uncategorized',
        amount: 1456.5,
        percentage: 26.4,
        color: Color(0xFF737373),
      ),
    ];
    const prompts = <_PromptCardData>[
      _PromptCardData(
        title: 'Update',
        description:
            'Your side hustle income could cover groceries and several other expenses, reducing the need for a loan. Consider redirecting your side hustle earnings to priority expenses like groceries before borrowing.',
      ),
      _PromptCardData(
        title: 'Show spending insights',
        description: 'We update this data weekly with fresh insights.',
      ),
      _PromptCardData(
        title: 'Your turn soon',
        description:
            'You will soon be able to get personalized insights just like this.',
      ),
      _PromptCardData(
        title: 'M-PESA integration',
        description:
            'We are working on integrating M-PESA to make it easier to add income and expenses.',
      ),
    ];

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              const _IntroHeaderCard(),
              const SizedBox(height: 16),
              _SummaryCard(summary: summary),
              const SizedBox(height: 16),
              _InsightListCard(title: 'Income sources', lines: incomeSources),
              const SizedBox(height: 16),
              _InsightListCard(title: 'Spending breakdown', lines: spending),
              const SizedBox(height: 16),
              ...prompts.map((prompt) => Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: _PromptCard(data: prompt),
                  )),
            ],
          ),
        ),
      ),
    );
  }
}

class _IntroHeaderCard extends StatelessWidget {
  const _IntroHeaderCard();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Stack(
          children: <Widget>[
            Align(
              alignment: Alignment.topRight,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceVariant,
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: theme.dividerColor),
                ),
                child: Text(
                  'Coming Soon!',
                  style: theme.textTheme.labelSmall,
                ),
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'Budget Analyser Preview',
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'See how average students in Nairobi spend their money.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.textTheme.bodySmall?.color,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.summary});

  final _CashflowSummary summary;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'Cash flow snapshot',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 12),
            _SummaryRow(
              label: 'Total income',
              value: _formatCurrency(summary.currency, summary.totalIncome),
            ),
            const SizedBox(height: 6),
            _SummaryRow(
              label: 'Total spending',
              value: _formatCurrency(summary.currency, summary.totalSpending),
            ),
            const SizedBox(height: 6),
            _SummaryRow(
              label: 'Surplus',
              value: _formatCurrency(summary.currency, summary.surplus),
              valueStyle: theme.textTheme.bodyMedium?.copyWith(
                color: const Color(0xFF10A861),
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SummaryRow extends StatelessWidget {
  const _SummaryRow({
    required this.label,
    required this.value,
    this.valueStyle,
  });

  final String label;
  final String value;
  final TextStyle? valueStyle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: <Widget>[
        Text(
          label,
          style: theme.textTheme.bodyMedium,
        ),
        Text(
          value,
          style: valueStyle ?? theme.textTheme.bodyMedium,
        ),
      ],
    );
  }
}

class _InsightListCard extends StatelessWidget {
  const _InsightListCard({required this.title, required this.lines});

  final String title;
  final List<_InsightLine> lines;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              title,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 12),
            ...lines.map((line) => Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: _InsightRow(line: line),
                )),
          ],
        ),
      ),
    );
  }
}

class _InsightRow extends StatelessWidget {
  const _InsightRow({required this.line});

  final _InsightLine line;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: <Widget>[
        Row(
          children: <Widget>[
            Container(
              width: 10,
              height: 10,
              margin: const EdgeInsets.only(right: 8),
              decoration: BoxDecoration(
                color: line.color,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
            Text(
              line.label,
              style: theme.textTheme.bodyMedium,
            ),
          ],
        ),
        Text(
          '${_formatCurrency(line.currency, line.amount)} • ${_formatPercent(line.percentage)}',
          style: theme.textTheme.bodySmall,
        ),
      ],
    );
  }
}

class _PromptCard extends StatelessWidget {
  const _PromptCard({required this.data});

  final _PromptCardData data;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              data.title,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              data.description,
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _CashflowSummary {
  const _CashflowSummary({
    required this.totalIncome,
    required this.totalSpending,
    required this.surplus,
    required this.currency,
  });

  final double totalIncome;
  final double totalSpending;
  final double surplus;
  final String currency;
}

class _InsightLine {
  const _InsightLine({
    required this.label,
    required this.amount,
    required this.percentage,
    required this.color,
    this.currency = 'KSh',
  });

  final String label;
  final double amount;
  final double percentage;
  final Color color;
  final String currency;
}

class _PromptCardData {
  const _PromptCardData({required this.title, required this.description});

  final String title;
  final String description;
}

String _formatCurrency(String currency, double amount) {
  final fixed = amount.toStringAsFixed(2);
  final parts = fixed.split('.');
  final whole = parts[0];
  final fraction = parts[1];
  final buffer = StringBuffer();

  for (var i = 0; i < whole.length; i += 1) {
    final reverseIndex = whole.length - i;
    buffer.write(whole[i]);
    if (reverseIndex > 1 && reverseIndex % 3 == 1) {
      buffer.write(',');
    }
  }

  return '$currency${buffer.toString()}.$fraction';
}

String _formatPercent(double value) {
  return '${value.toStringAsFixed(1)}%';
}
