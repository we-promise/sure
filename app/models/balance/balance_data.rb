Balance::BalanceData = Struct.new(
  :account, :date, :currency, :balance, :cash_balance,
  :start_cash_balance, :start_non_cash_balance,
  :cash_inflows, :cash_outflows,
  :non_cash_inflows, :non_cash_outflows,
  :cash_adjustments, :non_cash_adjustments,
  :net_market_flows, :flows_factor,
  :holdings_valued_at_parity,
  keyword_init: true
) do
  # False unless the calculator says a holding was valued at 1:1.
  def initialize(holdings_valued_at_parity: false, **attributes)
    super
  end
end
