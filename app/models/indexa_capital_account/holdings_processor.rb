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

    # The importer normalises to total_fiscal_results (one aggregated row
    # per security). Defensively dedupe in case a future variant feeds the
    # per-tax-lot fiscal_results array through here — same key extraction
    # as Processor#calculate_holdings_value via the shared DataHelpers
    # method, so the two can't disagree on which rows refer to the same
    # security.
    per_security = {}
    holdings_data.each do |holding_data|
      data = holding_data.respond_to?(:with_indifferent_access) ? holding_data.with_indifferent_access : holding_data
      key = extract_instrument_key(data)
      next if key.blank?

      per_security[key] = data
    end

    Rails.logger.info "IndexaCapitalAccount::HoldingsProcessor - Processing #{per_security.size} holdings (from #{holdings_data.size} input rows)"

    per_security.each_value.with_index do |data, idx|
      Rails.logger.info "IndexaCapitalAccount::HoldingsProcessor - Processing holding #{idx + 1}/#{per_security.size}"
      process_holding(data)
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
      ticker = extract_instrument_key(data)
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
