import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../theme/sure_colors.dart';
import '../theme/sure_tokens.dart';
import '../widgets/sure_list_group.dart';
import 'calendar_screen.dart';
import 'recent_transactions_screen.dart';

class MoreScreen extends StatelessWidget {
  const MoreScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      body: ListView(
        children: [
          _buildMenuItem(
            context: context,
            icon: Icons.calendar_month,
            title: l.moreCalendar,
            subtitle: l.moreCalendarSubtitle,
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => const CalendarScreen(),
                ),
              );
            },
          ),
          Divider(height: 1, color: colorScheme.outlineVariant),
          _buildMenuItem(
            context: context,
            icon: Icons.receipt_long,
            title: l.moreRecentTransactions,
            subtitle: l.moreRecentTransactionsSubtitle,
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => const RecentTransactionsScreen(),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _iconBadge(BuildContext context, IconData icon) {
    final palette = SureColors.of(context).palette;
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: palette.surfaceInset,
        borderRadius: BorderRadius.circular(SureTokens.radiusMd),
      ),
      child: Icon(icon, color: palette.textPrimary),
    );
  }
}
