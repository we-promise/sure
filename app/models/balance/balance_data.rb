Balance::BalanceData = Struct.new(
  :account, :date, :currency, :balance, :cash_balance,
  :start_cash_balance, :start_non_cash_balance,
  :cash_inflows, :cash_outflows,
  :non_cash_inflows, :non_cash_outflows,
  :cash_adjustments, :non_cash_adjustments,
  :net_market_flows, :flows_factor,
  keyword_init: true
)
