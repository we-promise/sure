class InvestmentFlowStatement
  include Monetizable

  attr_reader :family

  def initialize(family)
    @family = family
  end

  # Get contribution/withdrawal totals for a period
  def period_totals(period: Period.current_month)
    transactions = family.transactions
      .visible
      .excluding_pending
      .where(entries: { date: period.date_range })
      .where(kind: %w[standard investment_contribution])
      .where(investment_activity_label: %w[Contribution Withdrawal])

    contributions = transactions.where(investment_activity_label: "Contribution").sum("entries.amount").abs
    withdrawals = transactions.where(investment_activity_label: "Withdrawal").sum("entries.amount").abs

    PeriodTotals.new(
      contributions: Money.new(contributions, family.currency),
      withdrawals: Money.new(withdrawals, family.currency),
      net_flow: Money.new(contributions - withdrawals, family.currency)
    )
  end

  PeriodTotals = Data.define(:contributions, :withdrawals, :net_flow)
end
