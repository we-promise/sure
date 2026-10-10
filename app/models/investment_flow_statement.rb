class InvestmentFlowStatement
  include Monetizable

  CONTRIBUTIONS_TOTAL_SQL = Arel.sql(
    "COALESCE(ABS(SUM(CASE WHEN transactions.investment_activity_label = 'Contribution' " \
    "THEN entries.amount ELSE 0 END)), 0)"
  )
  WITHDRAWALS_TOTAL_SQL = Arel.sql(
    "COALESCE(ABS(SUM(CASE WHEN transactions.investment_activity_label = 'Withdrawal' " \
    "THEN entries.amount ELSE 0 END)), 0)"
  )
  INVESTMENT_ACCOUNT_TYPES = %w[Investment Crypto].freeze
  private_constant :CONTRIBUTIONS_TOTAL_SQL, :WITHDRAWALS_TOTAL_SQL, :INVESTMENT_ACCOUNT_TYPES

  attr_reader :family, :user

  def initialize(family, user: nil)
    @family = family
    @user = user
  end

  # Get contribution/withdrawal totals for a period
  def period_totals(period: Period.current_month)
    base = family.transactions
      .visible
      .excluding_pending
      .where(entries: { date: period.date_range })
      .where(investment_activity_label: %w[Contribution Withdrawal])

    scope = base.where(kind: %w[standard investment_contribution]).excluding_pending_transfer_legs
      .or(matched_investment_flows(base))

    if user
      account_ids = family.accounts.included_in_finances_for(user).included_in_reports.select(:id)
      scope = scope.where(entries: { account_id: account_ids })
    end

    contributions, withdrawals = scope.pick(
      CONTRIBUTIONS_TOTAL_SQL,
      WITHDRAWALS_TOTAL_SQL
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
    # or crypto accounts stay internal and are not counted. A still-pending
    # auto-match keeps the leg's own kind until it is confirmed
    # (Transfer#confirm!), so it is counted by the same rule as a confirmed one.
    def matched_investment_flows(base)
      matched_flow(base, label: "Contribution", leg: :inflow_transaction_id, counterpart: :outflow_transaction)
        .or(matched_flow(base, label: "Withdrawal", leg: :outflow_transaction_id, counterpart: :inflow_transaction))
    end

    def matched_flow(base, label:, leg:, counterpart:)
      base
        .where(kind: "funds_movement")
        .or(base.where(kind: %w[standard investment_contribution]).pending_transfer_legs)
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
