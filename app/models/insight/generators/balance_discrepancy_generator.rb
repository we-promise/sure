# Flags accounts whose transaction history no longer adds up to the
# bank-reported balance — usually a missing or duplicated transaction that
# Balance::ReverseCalculator's reconciliation-waypoint reset silently
# absorbed instead of recording. Only meaningful for automatically
# synchronized accounts: on a manual account, a balance/transaction mismatch
# is the user's own deliberate choice, not a data error.
#
# Known limitation: Balance::IntegrityChecker needs 2+ Valuation waypoints to
# say anything at all. Several linked providers (e.g. SimpleFin, Up, Fio,
# Monobank, Wise, Brex, Mercury) update `accounts.balance` directly in their
# processors instead of rotating an anchor via Account#set_current_balance,
# so their accounts never accumulate waypoints and this generator silently
# never flags them — not a false positive, just no coverage yet. Fixing that
# means touching each provider's processor and is out of scope here.
class Insight::Generators::BalanceDiscrepancyGenerator < Insight::Generator
  produces "balance_discrepancy"

  # Realistically only ever a handful of accounts per family are linked +
  # Depository/CreditCard at all; matches the cap style of other generators
  # (IdleCashGenerator uses 2) without needing to be that tight here. Ordering
  # eligible_accounts deterministically (see below) means the same accounts
  # are always the ones capped out if this is ever exceeded, rather than an
  # unstable pick that could make an unrelated account's still-open insight
  # flap between active and expired from one nightly run to the next.
  MAX_INSIGHTS = 5

  def generate
    eligible_accounts.filter_map { |account| insight_for(account) }.first(MAX_INSIGHTS)
  end

  private
    # `.select` (Ruby, not SQL) runs one extra query per linked account to
    # check single_currency?, and Balance::IntegrityChecker#latest_flagged_gap
    # itself runs 2+ queries per account — so this generator's DB cost scales
    # with the family's linked-account count, not just MAX_INSIGHTS. Accepted
    # for now per the docstring's "realistically only a handful" assumption;
    # revisit if that stops holding in practice.
    def eligible_accounts
      family.accounts.visible.linked
        .where(accountable_type: %w[Depository CreditCard])
        .order(:created_at, :id) # stable order: see MAX_INSIGHTS comment above
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
        dedup_key: "balance_discrepancy:#{account.id}:#{since_date}",
        currency: account.currency
      )
    end
end
