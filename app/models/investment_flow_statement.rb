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
  private_constant :CONTRIBUTIONS_TOTAL_SQL, :WITHDRAWALS_TOTAL_SQL

  attr_reader :family, :user

  def initialize(family, user: nil)
    @family = family
    @user = user
  end

  # Get contribution/withdrawal totals for a period
  def period_totals(period: Period.current_month)
    scope = family.transactions
      .visible
      .excluding_pending
      .where(entries: { date: period.date_range })
      .where(kind: %w[standard investment_contribution])
      .where(investment_activity_label: %w[Contribution Withdrawal])

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
end
