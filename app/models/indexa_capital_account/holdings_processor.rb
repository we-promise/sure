# frozen_string_literal: true

class IndexaCapitalAccount::HoldingsProcessor
  include IndexaCapitalAccount::DataHelpers

  def initialize(indexa_capital_account)
    @indexa_capital_account = indexa_capital_account
  end

  def process
    return unless account.present?

    holdings_data = @indexa_capital_account.raw_holdings_payload
    return if holdings_data.blank?

    # Indexa returns a time series — many rows per security across dates.
    # Reduce to the latest-dated row per security so each holding reflects
    # the current position, not whichever snapshot happens to be processed
    # last in payload order.
    latest_per_security = {}
    holdings_data.each do |holding_data|
      data = holding_data.with_indifferent_access
      ticker = extract_ticker(data)
      next if ticker.blank?

      date = data[:date].to_s
      existing = latest_per_security[ticker]
      latest_per_security[ticker] = data if existing.nil? || date > existing[:date].to_s
    end

    Rails.logger.info "IndexaCapitalAccount::HoldingsProcessor - Processing #{latest_per_security.size} holdings (deduped from #{holdings_data.size} time-series rows)"

    latest_per_security.each_value.with_index do |holding_data, idx|
      Rails.logger.info "IndexaCapitalAccount::HoldingsProcessor - Processing holding #{idx + 1}/#{latest_per_security.size}"
      process_holding(holding_data)
    rescue => e
      Rails.logger.error "IndexaCapitalAccount::HoldingsProcessor - Failed to process holding #{idx + 1}: #{e.class} - #{e.message}"
      Rails.logger.error e.backtrace.first(5).join("\n") if e.backtrace
    end
  end

  private

    def account
      @indexa_capital_account.current_account
    end

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end

    # Indexa Capital fiscal-results field mapping:
    #   instrument.identifier (ISIN) → ticker
    #   instrument.name → security name
    #   titles → quantity (number of shares/units)
    #   price → current price per unit
    #   amount → total market value
    #   cost_price → average purchase price (cost basis per unit)
    #   cost_amount → total cost basis
    #   profit_loss → unrealized P&L
    #   subscription_date → purchase date
    def process_holding(data)
      ticker = extract_ticker(data)
      return if ticker.blank?

      Rails.logger.info "IndexaCapitalAccount::HoldingsProcessor - Processing holding for ticker: #{ticker}"

      security = resolve_security(ticker, data)
      return unless security

      quantity = parse_decimal(data[:titles]) || parse_decimal(data[:quantity]) || parse_decimal(data[:units])
      price = parse_decimal(data[:price])
      return if quantity.nil? || price.nil?

      amount = parse_decimal(data[:amount]) || (quantity * price)
      currency = "EUR" # Indexa Capital is EUR-only
      holding_date = Date.current

      Rails.logger.info "IndexaCapitalAccount::HoldingsProcessor - Importing holding: #{ticker} qty=#{quantity} price=#{price} currency=#{currency}"

      import_adapter.import_holding(
        security: security,
        quantity: quantity,
        amount: amount,
        currency: currency,
        date: holding_date,
        price: price,
        account_provider_id: @indexa_capital_account.account_provider&.id,
        source: "indexa_capital",
        delete_future_holdings: false
      )

      # Store cost basis from cost_price (average purchase price per unit)
      cost_price = parse_decimal(data[:cost_price])
      update_holding_cost_basis(security, cost_price) if cost_price.present?
    end

    # Extract ISIN from instrument data as ticker
    def extract_ticker(data)
      # Indexa Capital uses ISIN codes nested under instrument
      instrument = data[:instrument]
      if instrument.is_a?(Hash)
        instrument = instrument.with_indifferent_access
        return instrument[:identifier] || instrument[:isin]
      end

      # Fallback to flat fields
      data[:isin] || data[:identifier] || data[:symbol] || data[:ticker]
    end

    # Override security name extraction for Indexa Capital
    def extract_security_name(symbol_data, fallback_ticker)
      symbol_data = symbol_data.with_indifferent_access if symbol_data.respond_to?(:with_indifferent_access)

      instrument = symbol_data[:instrument]
      if instrument.is_a?(Hash)
        instrument = instrument.with_indifferent_access
        name = instrument[:name] || instrument[:description]
        return name if name.present?
      end

      name = symbol_data[:name] || symbol_data[:description]
      return fallback_ticker if name.blank? || name.is_a?(Hash)

      name
    end

    def update_holding_cost_basis(security, cost_price)
      holding = account.holdings
        .where(security: security)
        .where("cost_basis_source != 'manual' OR cost_basis_source IS NULL")
        .order(date: :desc)
        .first

      return unless holding

      cost_basis = parse_decimal(cost_price)
      return if cost_basis.nil?

      holding.update!(
        cost_basis: cost_basis,
        cost_basis_source: "provider"
      )
    end
end
