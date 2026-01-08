class TraderepublicItem::Importer
    # Utility to find or create a security by ISIN, otherwise by ticker/MIC
    def find_or_create_security_from_tr(position_or_txn)
      isin = position_or_txn["isin"]&.strip&.upcase.presence
      ticker = position_or_txn["ticker"]&.strip.presence || position_or_txn["symbol"]&.strip.presence
      mic = position_or_txn["exchange_operating_mic"]&.strip.presence || position_or_txn["mic"]&.strip.presence
      name = position_or_txn["name"]&.strip.presence

      TradeRepublic::SecurityResolver.new(isin, name: name, ticker: ticker, mic: mic).resolve
    end
  attr_reader :traderepublic_item, :provider

  def initialize(traderepublic_item, traderepublic_provider: nil)
    @traderepublic_item = traderepublic_item
    @provider = traderepublic_provider || traderepublic_item.traderepublic_provider
  end

  def import
    raise "Provider not configured" unless provider
    raise "Session not configured" unless traderepublic_item.session_configured?

    Rails.logger.info "TraderepublicItem #{traderepublic_item.id}: Starting import"

    # Import portfolio and create/update accounts
    import_portfolio

    # Import timeline transactions
    import_transactions

    # Mark sync as successful
    traderepublic_item.update!(status: :good)

    Rails.logger.info "TraderepublicItem #{traderepublic_item.id}: Import completed successfully"

    true
  rescue TraderepublicError => e
    Rails.logger.error "TraderepublicItem #{traderepublic_item.id}: Import failed - #{e.message}"

    # Mark as requires_update if authentication error
    if [ :unauthorized, :auth_failed ].include?(e.error_code)
      traderepublic_item.update!(status: :requires_update)
      raise e # Re-raise so the caller can handle re-auth
    end

    false
  rescue => e
    Rails.logger.error "TraderepublicItem #{traderepublic_item.id}: Import failed - #{e.class}: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    false
  end

  private

  def import_portfolio
    Rails.logger.info "TraderepublicItem #{traderepublic_item.id}: Fetching portfolio data"

    portfolio_data = provider.get_portfolio
    cash_data = provider.get_cash
    
    parsed_portfolio = if portfolio_data
                         portfolio_data.is_a?(String) ? JSON.parse(portfolio_data) : portfolio_data
                       else
                         {}
                       end
                       
    parsed_cash = if cash_data
                    cash_data.is_a?(String) ? JSON.parse(cash_data) : cash_data
                  else
                    nil
                  end

    # Get or create main account
    account = find_or_create_main_account(parsed_portfolio)

    # Update account with portfolio data
    update_account_with_portfolio(account, parsed_portfolio, parsed_cash)

    # Import holdings/positions
    import_holdings(account, parsed_portfolio)
  rescue JSON::ParserError => e
    Rails.logger.error "TraderepublicItem #{traderepublic_item.id}: Failed to parse portfolio data - #{e.message}"
  end

  def import_transactions

    begin
      Rails.logger.info "TraderepublicItem #{traderepublic_item.id}: Fetching transactions"

    # Find main account
    account = traderepublic_item.traderepublic_accounts.first
    return unless account

    # Get the date of the last synced transaction for incremental sync
    since_date = account.last_transaction_date
    # Force a full sync if no transaction actually exists
    if account.linked_account.nil? || !account.linked_account.transactions.exists?
      since_date = nil
      Rails.logger.info "TraderepublicItem #{traderepublic_item.id}: Forcing initial full sync (no transactions exist)"
    elsif since_date
      Rails.logger.info "TraderepublicItem #{traderepublic_item.id}: Incremental sync from #{since_date}"
    else
      Rails.logger.info "TraderepublicItem #{traderepublic_item.id}: Initial full sync"
    end

    transactions_data = provider.get_timeline_transactions(since: since_date)
      Rails.logger.info "TraderepublicItem #{traderepublic_item.id}: transactions_data class=#{transactions_data.class} keys=#{transactions_data.respond_to?(:keys) ? transactions_data.keys : 'n/a'}"
      Rails.logger.info "TraderepublicItem #{traderepublic_item.id}: transactions_data preview=#{transactions_data.inspect[0..300]}"
      return unless transactions_data

      parsed = transactions_data.is_a?(String) ? JSON.parse(transactions_data) : transactions_data
      Rails.logger.info "TraderepublicItem #{traderepublic_item.id}: parsed class=#{parsed.class} keys=#{parsed.respond_to?(:keys) ? parsed.keys : 'n/a'}"
      Rails.logger.info "TraderepublicItem #{traderepublic_item.id}: parsed preview=#{parsed.inspect[0..300]}"

      # Add instrument details for each transaction (if ISIN present)
      items = if parsed.is_a?(Hash)
        parsed["items"]
      elsif parsed.is_a?(Array)
        pair = parsed.find { |p| p[0] == "items" }
        pair ? pair[1] : nil
      end

    end # fin de import_transactions

  def extract_isin_from_icon(icon)
    return nil unless icon.is_a?(String)
    match = icon.match(%r{logos/([A-Z]{2}[A-Z0-9]{9}\d)/})
    match ? match[1] : nil
  end


      if items.is_a?(Array)
        Rails.logger.info "TraderepublicItem #{traderepublic_item.id}: items count before enrichment = #{items.size}"
        items.each do |txn|
          # Enrich with instrument_details (ISIN) if possible
          isin = txn["isin"]
          isin ||= txn.dig("instrument", "isin")
          isin ||= extract_isin_from_icon(txn["icon"])
          if isin.present? && isin.match?(/^[A-Z]{2}[A-Z0-9]{10}$/)
            begin
              instrument_details = provider.get_instrument_details(isin)
              txn["instrument_details"] = instrument_details if instrument_details.present?
            rescue => e
              Rails.logger.warn "TraderepublicItem #{traderepublic_item.id}: Failed to fetch instrument details for ISIN #{isin} - #{e.message}"
            end
          end
          # Enrich with trade_details (timelineDetailV2) for each transaction
          begin
            trade_details = provider.get_timeline_detail(txn["id"])
            txn["trade_details"] = trade_details if trade_details.present?
          rescue => e
            Rails.logger.warn "TraderepublicItem #{traderepublic_item.id}: Failed to fetch trade details for txn #{txn["id"]} - #{e.message}"
          end
        end
        Rails.logger.info "TraderepublicItem #{traderepublic_item.id}: items count after enrichment = #{items.size}"
      end



      # Detailed log before saving the snapshot
      items_count = items.is_a?(Array) ? items.size : 0
      preview = items.is_a?(Array) && items_count > 0 ? items.first(2).map { |i| i.slice('id', 'title', 'isin') } : items.inspect
      Rails.logger.info "TraderepublicItem #{traderepublic_item.id}: Transactions snapshot contains #{items_count} items (with instrument details). Preview: #{preview}"


      # Update account with transactions data
      account.upsert_traderepublic_transactions_snapshot!(parsed)
      Rails.logger.info "TraderepublicItem #{traderepublic_item.id}: Snapshot saved with #{items_count} items."

      # Process transactions
      process_transactions(account, parsed)
    rescue JSON::ParserError => e
      Rails.logger.error "TraderepublicItem #{traderepublic_item.id}: Failed to parse transactions - #{e.message}"
    rescue => e
      Rails.logger.error "TraderepublicItem #{traderepublic_item.id}: Unexpected error in import_transactions - #{e.class}: #{e.message}"
      Rails.logger.error e.backtrace.join("\n") if e.respond_to?(:backtrace)
      raise
    end

  def find_or_create_main_account(portfolio_data)
    # TradeRepublic typically has one main account
    account = traderepublic_item.traderepublic_accounts.first_or_initialize(
      account_id: "main",
      name: "Trade Republic",
      currency: "EUR"
    )

    account.save! if account.new_record?
    account
  end

  def update_account_with_portfolio(account, portfolio_data, cash_data = nil)
    # Extract cash/balance from portfolio if available
    cash_value = extract_cash_value(portfolio_data, cash_data)

    account.upsert_traderepublic_snapshot!({
      id: "main",
      name: "Trade Republic",
      currency: "EUR",
      balance: cash_value,
      status: "active",
      type: "investment",
      raw: portfolio_data
    })
  end

  def extract_cash_value(portfolio_data, cash_data = nil)
    # Try to extract cash value from cash_data first
    if cash_data.is_a?(Array) && cash_data.first.is_a?(Hash)
      # [{"accountNumber"=>"...", "currencyId"=>"EUR", "amount"=>1064.3}]
      return cash_data.first["amount"]
    end

    # Try to extract cash value from portfolio structure
    # This depends on the actual API response structure
    return 0 unless portfolio_data.is_a?(Hash)

    # Common patterns in trading APIs
    portfolio_data.dig("cash", "value") ||
      portfolio_data.dig("availableCash") ||
      portfolio_data.dig("balance") ||
      0
  end

  def import_holdings(account, portfolio_data)
    positions = extract_positions(portfolio_data)
    return if positions.empty?

    Rails.logger.info "TraderepublicItem #{traderepublic_item.id}: Processing #{positions.size} positions"

    linked_account = account.linked_account
    return unless linked_account

    positions.each do |position|
      security = find_or_create_security_from_tr(position)
      Holding.create!(
        account: linked_account,
        security: security,
        qty: position["quantity"],
        price: position["price"],
        date: position["date"],
        currency: position["currency"]
      )
    end
  end

  def extract_positions(portfolio_data)
    return [] unless portfolio_data.is_a?(Hash)

    # Extract positions based on the Portfolio interface structure
    categories = portfolio_data["categories"] || []

    positions = []
    categories.each do |category|
      next unless category["positions"].is_a?(Array)

      category["positions"].each do |position|
        positions << position
      end
    end

    positions
  end

  def process_transactions(account, transactions_data)
    return unless transactions_data.is_a?(Array)

    Rails.logger.info "TraderepublicItem #{traderepublic_item.id}: Processing #{transactions_data.size} transactions"

    linked_account = account.linked_account
    return unless linked_account

    transactions_data.each do |txn|
      security = find_or_create_security_from_tr(txn)
      Trade.create!(
        account: linked_account,
        security: security,
        qty: txn["quantity"],
        price: txn["price"],
        date: txn["date"],
        currency: txn["currency"]
      )
    end
  end
end
