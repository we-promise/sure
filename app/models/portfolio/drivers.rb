# Where a period's change in portfolio value came from.
#
# The components reconcile exactly to the period's change in value:
#
#   external_net + composition + income - fees + market + revaluations + fx_effect
#     == value_close - value_open
#
# TWO THINGS ARE EASY TO GET WRONG HERE.
#
# First, `balances.net_market_flows` is only populated for investment accounts on
# days WITHOUT a valuation (Balance::BaseCalculator#market_value_change_on_date
# returns 0 otherwise, and the forward calculator skips it entirely on a
# valuation day). When a valuation overrides the balance, the whole move lands
# in cash_adjustments / non_cash_adjustments instead. Reporting only
# `net_market_flows` as "market" would therefore show a flat zero market return
# for every manually valued account. Those adjustments are reported here as
# `revaluations`, and Portfolio::ReturnScope tells the UI which label an account
# has earned.
#
# Second, `fx_effect` is MEASURED, not inferred. Portfolio::DailyReturns computes
# it per day as the closing local balance times that day's rate change, and the
# local components are converted at the previous day's rate, so the two halves
# add up to the day's change by construction rather than by definition.
#
# Defining fx_effect as the residual of the equation above would make
# `reconciles?` a tautology -- it could not return false, so the
# decomposition would be guarded by an assertion that could not
# fail, and a portfolio whose value moved for no recorded reason would report
# the whole move as currency movement. `unexplained` carries that gap openly.
class Portfolio::Drivers
  attr_reader :daily_returns

  def initialize(daily_returns)
    @daily_returns = daily_returns
  end

  def rows
    daily_returns.rows
  end

  def value_open
    @value_open ||= rows.first&.value_open || BigDecimal(0)
  end

  def value_close
    @value_close ||= rows.last&.value_close || BigDecimal(0)
  end

  def change
    value_close - value_open
  end

  # Net external contribution: deposits and transfers in, less withdrawals.
  def external_net
    @external_net ||= sum(:external_flow)
  end

  # Dividends and interest thrown off by the holdings, whether stored as a
  # Trade or as a Transaction.
  def income
    @income ||= sum(:income)
  end

  # Reported as a positive magnitude; it reduces the change. Returns are net
  # of fees, because a fee already lowered the balance it was charged from.
  def fees
    @fees ||= sum(:fees)
  end

  # Market movement on trade-tracked accounts.
  def market
    @market ||= sum(:market)
  end

  # Valuation and reconciliation movement. For a valuation-tracked
  # account this carries the entire market move.
  def revaluations
    @revaluations ||= sum(:revaluations)
  end

  # Measured per day from the rate change, not inferred.
  def fx_effect
    @fx_effect ||= sum(:fx_effect)
  end

  # Value that entered the scope (an account's opening position arriving
  # mid-period, positive) less value that left it (an account's balance carried
  # out at its cut-off, negative). A change in what the scope contains, not in
  # what it is worth.
  def composition
    @composition ||= sum(:composition_flow)
  end

  # What the named components do not account for. Expected to be zero, and a
  # real assertion because nothing defines it to be.
  #
  # An account entering or leaving the scope is described by `composition`, so
  # it no longer lands here. What is left is value that moved for a reason no
  # driver records -- and surfacing it is still the honest answer, rather than
  # folding it into whichever component is defined last.
  def unexplained
    @unexplained ||= change - (external_net + composition + income - fees + market + revaluations + fx_effect)
  end

  # For an account whose scope is :valuation_tracked, the market move lives in
  # `revaluations`. Callers that want one "the holdings moved" figure without
  # caring which shape the account is should use this.
  def market_including_revaluations
    market + revaluations
  end

  def to_h
    {
      value_open: value_open,
      value_close: value_close,
      change: change,
      external_net: external_net,
      composition: composition,
      income: income,
      fees: fees,
      market: market,
      revaluations: revaluations,
      fx_effect: fx_effect,
      unexplained: unexplained
    }
  end

  # One minor unit. Not academic slack: a multi-currency family accumulates
  # sub-cent residue by construction, because entry flows convert entry ->
  # family at t-1 while balance-row flows went entry -> account at the entry
  # date and then account -> family. At exact zero an ordinary residual of
  # 0.004 raises the "these figures do not reconcile" banner and prints an
  # "Unexplained $0.00" row, which is alarming and wrong.
  #
  # Named here so that anything presenting these figures reads the same
  # tolerance #reconciles? applies, rather than writing out its own literal:
  # two copies drift, and a period then reconciles in one place and not in
  # the other.
  #
  # Known limitation: one minor unit assumes two decimal places. JPY, KRW and
  # CLP carry `default_precision: 0` in config/currencies.yml, so a residual of
  # 0.3 JPY is above this and the row prints "Unexplained JPY 0". Expressing
  # the tolerance in the family currency's own minor unit is a change of
  # meaning, not of this constant.
  RECONCILE_TOLERANCE = BigDecimal("0.01")

  # A real check: `unexplained` is measured independently of the components
  # it is compared against, so this returns false when the decomposition does
  # not hold.
  def reconciles?(tolerance: RECONCILE_TOLERANCE)
    unexplained.abs <= tolerance
  end

  private
    def sum(field)
      rows.sum(BigDecimal(0)) { |row| row.public_send(field) }
    end
end
