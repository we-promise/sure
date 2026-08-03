class SnaptradeAccount::HoldingsProcessor
  include SnaptradeAccount::DataHelpers

  def initialize(snaptrade_account)
    @snaptrade_account = snaptrade_account
  end

  def process
    return unless account.present?

    holdings_data = @snaptrade_account.raw_holdings_payload

    if holdings_data.present?
      Rails.logger.info "SnaptradeAccount::HoldingsProcessor - Processing #{holdings_data.size} holdings"

      # Log sample of first holding to understand structure
      if holdings_data.first
        sample = holdings_data.first
        Rails.logger.info "SnaptradeAccount::HoldingsProcessor - Sample holding keys: #{sample.keys.first(10).join(', ')}"
        if sample["symbol"] || sample[:symbol]
          symbol_sample = sample["symbol"] || sample[:symbol]
          Rails.logger.info "SnaptradeAccount::HoldingsProcessor - Symbol data keys: #{symbol_sample.keys.first(10).join(', ')}" if symbol_sample.is_a?(Hash)
        end
      end

      holdings_data.each_with_index do |holding_data, idx|
        Rails.logger.info "SnaptradeAccount::HoldingsProcessor - Processing holding #{idx + 1}/#{holdings_data.size}"
        process_holding(holding_data.with_indifferent_access)
      rescue => e
        Rails.logger.error "SnaptradeAccount::HoldingsProcessor - Failed to process holding #{idx + 1}: #{e.class} - #{e.message}"
        Rails.logger.error e.backtrace.first(5).join("\n") if e.backtrace
      end
    end

    # Always run, even with no security holdings — secondary-currency cash
    # should still be surfaced (issue #1809).
    process_cash_holdings
  end

  private

    # Surface cash held in currencies other than the account's primary currency
    # as synthetic cash holdings (issue #1809). The primary currency stays in
    # account.cash_balance; without this, SnapTrade's secondary-currency cash
    # (e.g. USD cash in a CAD account) was silently discarded.
    def process_cash_holdings
      @snaptrade_account.non_primary_cash_entries.each do |entry|
        amount = parse_decimal(entry[:amount])
        next if amount.nil?

        # SnapTrade's per-currency cash includes money market / sweep funds
        # that are also reported as `cash_equivalent: true` positions and
        # imported as holdings — remove the overlap so the synthetic cash
        # holding doesn't double count them.
        amount -= @snaptrade_account.cash_equivalent_position_value(entry[:currency])

        security = Security.cash_for(account, currency: entry[:currency])

        Rails.logger.info "SnaptradeAccount::HoldingsProcessor - Importing #{entry[:currency]} cash holding"

        import_adapter.import_holding(
          security: security,
          quantity: amount,
          amount: amount,
          currency: entry[:currency],
          date: Date.current,
          price: 1,
          external_id: "snaptrade_cash_#{entry[:currency].to_s.downcase}",
          account_provider_id: @snaptrade_account.account_provider&.id,
          source: "snaptrade",
          delete_future_holdings: false
        )
      rescue => e
        Rails.logger.error "SnaptradeAccount::HoldingsProcessor - Failed to import #{entry[:currency]} cash holding: #{e.class} - #{e.message}"
      end
    end

    def account
      @snaptrade_account.current_account
    end

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end

    def process_holding(data)
      # Extract security info from the holding
      # SnapTrade has DEEPLY NESTED structure:
      #   holding.symbol.symbol.symbol = ticker (e.g., "TSLA")
      #   holding.symbol.symbol.description = name (e.g., "Tesla Inc")
      raw_symbol_wrapper = data["symbol"] || data[:symbol] || {}
      symbol_wrapper = raw_symbol_wrapper.is_a?(Hash) ? raw_symbol_wrapper.with_indifferent_access : {}

      # The actual security data is nested inside symbol.symbol
      raw_symbol_data = symbol_wrapper["symbol"] || symbol_wrapper[:symbol] || {}
      symbol_data = raw_symbol_data.is_a?(Hash) ? raw_symbol_data.with_indifferent_access : {}

      # Get the ticker - it's at symbol.symbol.symbol
      ticker = symbol_data["symbol"] || symbol_data[:symbol]

      # If that's still a hash, we need to go deeper or use raw_symbol
      if ticker.is_a?(Hash)
        ticker = symbol_data["raw_symbol"] || symbol_data[:raw_symbol]
      end

      return if ticker.blank?

      Rails.logger.info "SnaptradeAccount::HoldingsProcessor - Processing holding for ticker: #{ticker}"

      # Resolve or create the security
      security = resolve_security(ticker, symbol_data)
      return unless security

      # Parse values
      quantity = parse_decimal(data["units"] || data[:units])
      price = parse_decimal(data["price"] || data[:price])
      return if quantity.nil? || price.nil?

      # Calculate amount
      amount = quantity * price

      # Get the holding date (use current date if not provided)
      holding_date = Date.current

      # Extract currency - it can be at the holding level or in symbol_data
      currency_data = data["currency"] || data[:currency] || symbol_data["currency"] || symbol_data[:currency]
      currency = if currency_data.is_a?(Hash)
        currency_data.with_indifferent_access["code"]
      elsif currency_data.is_a?(String)
        currency_data
      else
        account.currency
      end

      Rails.logger.info "SnaptradeAccount::HoldingsProcessor - Importing holding: #{ticker} qty=#{quantity} price=#{price} currency=#{currency}"

      # Import the holding via the adapter
      import_adapter.import_holding(
        security: security,
        quantity: quantity,
        amount: amount,
        currency: currency,
        date: holding_date,
        price: price,
        account_provider_id: @snaptrade_account.account_provider&.id,
        source: "snaptrade",
        delete_future_holdings: false,
        cash_equivalent: data[:cash_equivalent] == true
      )

      # Store cost basis if available
      avg_price = data["average_purchase_price"] || data[:average_purchase_price]
      if avg_price.present?
        update_holding_cost_basis(security, avg_price)
      end
    end

    def update_holding_cost_basis(security, avg_cost)
      # Find the most recent holding and update cost basis if not locked
      holding = account.holdings
        .where(security: security)
        .where("cost_basis_source != 'manual' OR cost_basis_source IS NULL")
        .order(date: :desc)
        .first

      return unless holding

      # Store per-share cost, not total cost (cost_basis is per-share across the codebase)
      cost_basis = parse_decimal(avg_cost)
      return if cost_basis.nil?

      holding.update!(
        cost_basis: cost_basis,
        cost_basis_source: "provider"
      )
    end
end
