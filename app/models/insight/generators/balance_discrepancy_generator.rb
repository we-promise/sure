# Flags accounts whose transaction history no longer adds up to the
# bank-reported balance — usually a missing or duplicated transaction that
# Balance::ReverseCalculator's reconciliation-waypoint reset silently
# absorbed instead of recording. Only meaningful for automatically
# synchronized accounts: on a manual account, a balance/transaction mismatch
# is the user's own deliberate choice, not a data error.
class Insight::Generators::BalanceDiscrepancyGenerator < Insight::Generator
  produces "balance_discrepancy"

  # Realistically only ever a handful of accounts per family are linked +
  # Depository/CreditCard at all; matches the cap style of other generators
  # (IdleCashGenerator uses 2) without needing to be that tight here.
  MAX_INSIGHTS = 5

  def generate
    eligible_accounts.filter_map { |account| insight_for(account) }.first(MAX_INSIGHTS)
  end

  private
    def eligible_accounts
      family.accounts.visible.linked
        .where(accountable_type: %w[Depository CreditCard])
        .select { |a| single_currency?(a) }
    end

    # A bank account is inherently single-currency — foreign-currency
    # transactions are already converted by the bank before Sure sees them.
    # The rare exception (e.g. a bad CSV import artifact) would make FX rate
    # lookups a second variable on top of the gap itself, so those accounts
    # are excluded entirely rather than taught a second code path.
    def single_currency?(account)
      account.entries.excluding_pending.where.not(currency: account.currency).none?
    end

    def insight_for(account)
      gap = Balance::IntegrityChecker.new(account).latest_flagged_gap
      return nil unless gap

      since_date = gap.first_open_waypoint.date
      days_open = (gap.latest_waypoint.date - since_date).to_i

      build_insight(
        insight_type: "balance_discrepancy",
        priority: "high",
        title: I18n.t("insights.titles.balance_discrepancy", account: account.name),
        template_key: "balance_discrepancy",
        facts: {
          account: account.name,
          # gap.difference is in the account's own currency, which can differ
          # from family.currency — format_money (Insight::Generator) assumes
          # family.currency, so it can't be reused here.
          difference: Money.new(gap.difference, account.currency).format,
          since: I18n.l(since_date, format: :long),
          days_open: days_open
        },
        metadata: { account_id: account.id, since_date: since_date.to_s, difference: round(gap.difference, 2) },
        dedup_key: "balance_discrepancy:#{account.id}:#{since_date}"
      )
    end
end
