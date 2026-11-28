class InvestmentFlowStatement
  include Monetizable

  INVESTMENT_ACCOUNT_TYPES = %w[Investment Crypto].freeze
  private_constant :INVESTMENT_ACCOUNT_TYPES

  attr_reader :family, :user

  def initialize(family, user: nil)
    @family = family
    @user = user
  end

  # Get contribution/withdrawal totals for a period
  def period_totals(period: Period.current_month)
    # From Transaction rather than family.transactions: `visible` joins the
    # entry and its account itself, and the association's own copies of those
    # joins left the date filter on one copy only, so Postgres matched every
    # candidate transaction against every transaction entry of the family.
    base = Transaction
      .visible
      .excluding_pending
      .where(entries: { account_id: family.accounts.select(:id), date: period.date_range })
      .where(investment_activity_label: %w[Contribution Withdrawal])

    scope = base.where(kind: %w[standard investment_contribution])
      .or(matched_investment_flows(base))

    if user
      account_ids = family.accounts.included_in_finances_for(user).included_in_reports.select(:id)
      scope = scope.where(entries: { account_id: account_ids })
    end

    # Convert each entry into the family currency on its own date; entries whose
    # currency has no stored rate evaluate to NULL and are skipped by SUM rather
    # than counted at parity (see ExchangeRate.rate_sql).
    rate = ExchangeRate.rate_sql(from: "entries.currency", to: ":currency", on: "entries.date")
    contributions_sql = Transaction.sanitize_sql_array([
      "COALESCE(ABS(SUM(CASE WHEN transactions.investment_activity_label = 'Contribution' THEN entries.amount * (#{rate}) ELSE 0 END)), 0)",
      { currency: family.currency }
    ])
    withdrawals_sql = Transaction.sanitize_sql_array([
      "COALESCE(ABS(SUM(CASE WHEN transactions.investment_activity_label = 'Withdrawal' THEN entries.amount * (#{rate}) ELSE 0 END)), 0)",
      { currency: family.currency }
    ])

    contributions, withdrawals = scope.pick(
      Arel.sql(contributions_sql),
      Arel.sql(withdrawals_sql)
    )

    PeriodTotals.new(
      contributions: Money.new(contributions, family.currency),
      withdrawals: Money.new(withdrawals, family.currency),
      net_flow: Money.new(contributions - withdrawals, family.currency)
    )
  end

  PeriodTotals = Data.define(:contributions, :withdrawals, :net_flow)

  private
    # Matching a provider "Contribution" or "Withdrawal" on an investment/crypto
    # account to its cash counterpart turns that leg into funds_movement
    # (Transfer#kind_for_leg), so the kind filter above would drop it. Count it
    # when the other leg is outside the investment/crypto accounts, the same
    # endpoint rule Transfer.kind_for_account uses. Movements between investment
    # or crypto accounts stay internal and are not counted.
    def matched_investment_flows(base)
      matched_flow(base, label: "Contribution", leg: :inflow_transaction_id, counterpart: :outflow_transaction)
        .or(matched_flow(base, label: "Withdrawal", leg: :outflow_transaction_id, counterpart: :inflow_transaction))
    end

    def matched_flow(base, label:, leg:, counterpart:)
      base
        .where(kind: "funds_movement")
        .where("transactions.investment_activity_label = ?", label)
        .where(entries: { account_id: family.accounts.where(accountable_type: INVESTMENT_ACCOUNT_TYPES).select(:id) })
        .where(
          id: Transfer
            .joins(counterpart => { entry: :account })
            .where(accounts: { family_id: family.id })
            .where.not(accounts: { accountable_type: INVESTMENT_ACCOUNT_TYPES })
            .select(leg)
        )
    end
end
