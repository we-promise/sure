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

    Rails.logger.info "IndexaCapitalAccount::HoldingsProcessor - Processing #{holdings_data.size} holdings"

    # Log sample of first holding to understand structure
    if holdings_data.first
      sample = holdings_data.first
      Rails.logger.info "IndexaCapitalAccount::HoldingsProcessor - Sample holding keys: #{sample.keys.first(10).join(', ')}"
    end

    holdings_data.each_with_index do |holding_data, idx|
      Rails.logger.info "IndexaCapitalAccount::HoldingsProcessor - Processing holding #{idx + 1}/#{holdings_data.size}"
      process_holding(holding_data.with_indifferent_access)
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

    def process_holding(data)
      # TODO: Customize ticker extraction based on your provider's format
      # Example: ticker = data[:symbol] || data[:ticker]
      ticker = extract_ticker(data)
      return if ticker.blank?

      Rails.logger.info "IndexaCapitalAccount::HoldingsProcessor - Processing holding for ticker: #{ticker}"

      # Resolve or create the security
      security = resolve_security(ticker, data)
      return unless security

      # TODO: Customize field names based on your provider's format
      quantity = parse_decimal(data[:units] || data[:quantity])
      price = parse_decimal(data[:price])
      return if quantity.nil? || price.nil?

      # Calculate amount
      amount = quantity * price

      # Get the holding date (use current date if not provided)
      holding_date = Date.current

      # Extract currency
      currency = extract_currency(data, fallback: account.currency)

      Rails.logger.info "IndexaCapitalAccount::HoldingsProcessor - Importing holding: #{ticker} qty=#{quantity} price=#{price} currency=#{currency}"

      # Import the holding via the adapter
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

      # Store cost basis if available
      # TODO: Customize cost basis field name
      avg_price = data[:average_purchase_price] || data[:cost_basis] || data[:avg_cost]
      if avg_price.present?
        update_holding_cost_basis(security, avg_price)
      end
    end

    def extract_ticker(data)
      # TODO: Customize based on your provider's format
      # Some providers nest symbol data, others have it flat
      #
      # Example for flat structure:
      #   data[:symbol] || data[:ticker]
      #
      # Example for nested structure:
      #   symbol_data = data[:symbol] || {}
      #   symbol_data = symbol_data[:symbol] if symbol_data.is_a?(Hash)
      #   symbol_data.is_a?(String) ? symbol_data : symbol_data[:ticker]

      data[:symbol] || data[:ticker]
    end

    def update_holding_cost_basis(security, avg_cost)
      # Find the most recent holding and update cost basis if not locked
      holding = account.holdings
        .where(security: security)
        .where("cost_basis_source != 'manual' OR cost_basis_source IS NULL")
        .order(date: :desc)
        .first

      return unless holding

      # Store per-share cost, not total cost
      cost_basis = parse_decimal(avg_cost)
      return if cost_basis.nil?

      holding.update!(
        cost_basis: cost_basis,
        cost_basis_source: "provider"
      )
    end
end
