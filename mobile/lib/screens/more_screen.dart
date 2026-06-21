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
    return Scaffold(
      // Setting an explicit ListView padding opts out of the scroll view's
      // automatic safe-area inset, so restore it with SafeArea (keeps the group
      // clear of the status bar / home indicator).
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            SureListGroup(
              children: [
                SureListRow(
                  leading: _iconBadge(context, Icons.calendar_month),
                  title: l.moreCalendar,
                  subtitle: l.moreCalendarSubtitle,
                  showChevron: true,
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => const CalendarScreen(),
                      ),
                    );
                  },
                ),
                SureListRow(
                  leading: _iconBadge(context, Icons.receipt_long),
                  title: l.moreRecentTransactions,
                  subtitle: l.moreRecentTransactionsSubtitle,
                  showChevron: true,
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => const RecentTransactionsScreen(),
                      ),
                    );
                  },
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
