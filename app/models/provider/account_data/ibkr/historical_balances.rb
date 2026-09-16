require "set"

# Pure post-materialization projection. The caller supplies the account's already
# calculated cash balances and all of its trade flows in base currency, including
# manually entered trades. This class does not query or mutate financial models.
class Provider::AccountData::Ibkr::HistoricalBalances
  def self.project(equity_rows:, currency:, existing_balances:, trade_flows:, failed_fx_dates: [], retained_totals: {}, anchor_date:, observed_on:)
    new(equity_rows: equity_rows, currency: currency, existing_balances: existing_balances, trade_flows: trade_flows,
      failed_fx_dates: failed_fx_dates, retained_totals: retained_totals, anchor_date: anchor_date, observed_on: observed_on).project
  end

  def initialize(equity_rows:, currency:, existing_balances:, trade_flows:, failed_fx_dates:, retained_totals: {}, anchor_date:, observed_on:)
    raise ArgumentError unless equity_rows.is_a?(Array) && existing_balances.is_a?(Hash) && trade_flows.is_a?(Hash)
    raise ArgumentError unless currency.is_a?(String) && currency.match?(/\A[A-Z]{3}\z/)
    @equity_rows, @currency = equity_rows, currency
    @existing = existing_balances.to_h { |day, values| [ date(day), values ] }
    @flows = trade_flows.to_h { |day, amount| [ date(day), decimal(amount) ] }
    raise ArgumentError unless @existing.size == existing_balances.size && @flows.size == trade_flows.size
    @failed = failed_fx_dates.map { |day| date(day) }.to_set
    raise ArgumentError unless retained_totals.is_a?(Hash)
    @retained = retained_totals.to_h { |day, total| [ date(day), decimal(total) ] }
    raise ArgumentError unless @retained.size == retained_totals.size
    @observed_on = date(observed_on)
    @anchor_date = anchor_date ? date(anchor_date) : @observed_on
    @existing.each_key { |day| cash_for(day) }
  end

  def project
    rows = normalized_rows
    return [] if rows.empty?
    by_date = rows.index_by { |row| row.fetch(:date) }
    last_date = [ rows.last.fetch(:date), [ @anchor_date, @observed_on ].min ].max
    if last_date - rows.first.fetch(:date) > 36_600
      raise Provider::AccountData::IncompletePage, "IBKR equity history exceeds the reviewed projection range"
    end
    projection_dates = rows.first.fetch(:date)..last_date
    unless @failed.select { |day| projection_dates.cover?(day) }.all? { |day| @retained.key?(day) && @existing.key?(day) }
      raise Provider::AccountData::IncompletePage, "Failed FX dates must retain their materialized balance before historical overrides"
    end
    prior = nil
    last_total = nil
    (rows.first.fetch(:date)..last_date).filter_map do |day|
      last_total = by_date.fetch(day).fetch(:total) if by_date.key?(day)
      cash = cash_for(day)
      non_cash = @retained.fetch(day, last_total) - cash
      start_cash = prior ? prior.fetch(:cash) : cash
      start_non_cash = prior ? prior.fetch(:non_cash) : non_cash
      net_trades = prior ? @flows.fetch(day, BigDecimal("0")) : BigDecimal("0")
      market = prior ? non_cash - start_non_cash - net_trades : BigDecimal("0")
      prior = { cash: cash, non_cash: non_cash }
      next if @failed.include?(day) || @retained.key?(day)
      { date: day, currency: @currency, balance: last_total, cash_balance: cash,
        start_cash_balance: start_cash, start_non_cash_balance: start_non_cash,
        cash_inflows: BigDecimal("0"), cash_outflows: BigDecimal("0"), non_cash_inflows: BigDecimal("0"), non_cash_outflows: BigDecimal("0"),
        net_market_flows: market, cash_adjustments: cash - start_cash, non_cash_adjustments: net_trades, flows_factor: BigDecimal("1") }
    end
  end

  private
    def normalized_rows
      rows = @equity_rows.filter_map do |raw|
        raise ArgumentError unless raw.is_a?(Hash)
        row = raw.with_indifferent_access
        currency = row[:currency].presence&.upcase
        next if currency == "BASE_SUMMARY" || (currency.present? && currency != @currency)
        day = date(row.fetch(:report_date))
        raise ArgumentError if day > @observed_on
        { date: day, total: decimal(row.fetch(:total)) }
      end.sort_by { |row| row.fetch(:date) }
      if rows.group_by { |row| row.fetch(:date) }.any? { |_date, values| values.map { |row| row.fetch(:total) }.uniq.size > 1 }
        raise ArgumentError, "Conflicting IBKR equity totals for one date"
      end
      rows.uniq { |row| row.fetch(:date) }
    end

    def cash_for(day)
      values = @existing[day]
      return BigDecimal("0") unless values
      raise ArgumentError unless values.is_a?(Hash)
      cash = values.with_indifferent_access[:cash_balance]
      cash.nil? ? BigDecimal("0") : decimal(cash)
    end

    def date(value)
      Provider::AccountData::Ibkr::Values.date(value)
    end

    def decimal(value)
      Provider::AccountData::Ibkr::Values.decimal(value)
    end
end
