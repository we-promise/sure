require "digest"

module Ingestion::HistoricalBalances
  FORMAT = "historical_balances/v1"
  COLUMNS = %i[date currency balance cash_balance start_cash_balance start_non_cash_balance cash_inflows cash_outflows
    non_cash_inflows non_cash_outflows net_market_flows cash_adjustments non_cash_adjustments flows_factor].freeze
  MONEY_COLUMNS = (COLUMNS - %i[date currency flows_factor]).freeze

  def self.fingerprint(value)
    Digest::SHA256.hexdigest(Provider::AccountData::MigrationValue.dump(value))
  end
end
