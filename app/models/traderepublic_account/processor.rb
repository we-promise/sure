class TraderepublicAccount::Processor
  attr_reader :traderepublic_account

  def initialize(traderepublic_account)
    @traderepublic_account = traderepublic_account
  end

  def process
    account = traderepublic_account.linked_account
    return unless account

    # Wrap deletions in a transaction so trades and Entry deletions succeed or roll back together
    Account.transaction do
      if account.respond_to?(:trades)
        deleted_count = account.trades.delete_all
        Rails.logger.info "TraderepublicAccount::Processor - #{deleted_count} trades for account ##{account.id} deleted before reprocessing."
      end

      Entry.where(account_id: account.id, source: "traderepublic").delete_all
      Rails.logger.info "TraderepublicAccount::Processor - All Entry records for account ##{account.id} deleted before reprocessing."
    end

    Rails.logger.info "TraderepublicAccount::Processor - Processing account #{account.id}"

    # Process transactions from raw payload
    process_transactions(account)

    # Process holdings from raw payload (calculate, then persist)
    begin
      Holding::Materializer.new(account, strategy: :forward).materialize_holdings
      Rails.logger.info "TraderepublicAccount::Processor - Holdings calculated and persisted."
    rescue => e
      Rails.logger.error "TraderepublicAccount::Processor - Error calculating/persisting holdings: #{e.message}"
      Rails.logger.error e.backtrace.first(5).join("\n")
    end

    # Persist balances using Balance::Materializer (strategy: :forward)
    begin
      Balance::Materializer.new(account, strategy: :forward).materialize_balances
      Rails.logger.info "TraderepublicAccount::Processor - Balances calculated and persisted."
    rescue => e
      Rails.logger.error "TraderepublicAccount::Processor - Error in Balance::Materializer: #{e.message}"
      Rails.logger.error e.backtrace.first(5).join("\n")
    end

    Rails.logger.info "TraderepublicAccount::Processor - Finished processing account #{account.id}"
  end

  private

  def process_transactions(account)
    transactions_data = traderepublic_account.raw_transactions_payload
    return unless transactions_data

    Rails.logger.info "[TR Processor] transactions_data loaded: #{transactions_data.class}"

    # Extract items array from the payload structure
    # Try both Hash and Array formats
    items = if transactions_data.is_a?(Hash)
              transactions_data["items"]
            elsif transactions_data.is_a?(Array)
              transactions_data.find { |pair| pair[0] == "items" }&.last
            end
    
    return unless items.is_a?(Array)

    Rails.logger.info "[TR Processor] items array size: #{items.size}"

    Rails.logger.info "TraderepublicAccount::Processor - Processing #{items.size} transactions"

    items.each do |txn|
      Rails.logger.info "[TR Processor] Processing txn id=#{txn['id']}"
      process_single_transaction(account, txn)
    end

    Rails.logger.info "TraderepublicAccount::Processor - Finished processing transactions"
  end

  def process_single_transaction(account, txn)
    # Skip if deleted or hidden
    if txn["deleted"]
      Rails.logger.info "[TR Processor] Skipping txn id=#{txn['id']} (deleted)"
      return
    end
    if txn["hidden"]
      Rails.logger.info "[TR Processor] Skipping txn id=#{txn['id']} (hidden)"
      return
    end
    unless txn["status"] == "EXECUTED"
      Rails.logger.info "[TR Processor] Skipping txn id=#{txn['id']} (status=#{txn['status']})"
      return
    end

    # Parse basic data
    traderepublic_id = txn["id"]
    title = txn["title"]
    subtitle = txn["subtitle"]
    amount_data = txn["amount"] || {}
    amount = amount_data["value"]
    currency = amount_data["currency"] || "EUR"
    timestamp = txn["timestamp"]
    
    unless traderepublic_id && timestamp && amount
      Rails.logger.info "[TR Processor] Skipping txn: missing traderepublic_id, timestamp, or amount (id=#{txn['id']})"
      return
    end

    # Trade Republic sends negative values for expenses (Buys) and positive values for income (Sells).
    # Sure expects negative = income and positive = expense, so we invert the sign here.
    amount = -amount.to_f

    # Parse date
    begin
      date = Time.parse(timestamp).to_date
    rescue StandardError => e
      Rails.logger.warn "TraderepublicAccount::Processor - Failed to parse timestamp #{timestamp.inspect} for txn #{traderepublic_id}: #{e.class}: #{e.message}. Falling back to Date.today"
      date = Date.today
    end

    # Check if this is a trade (Buy/Sell Order)
    # Note: subtitle contains the trade type info that becomes 'notes' after import
    is_trade_result = is_trade?(subtitle)
    
    Rails.logger.info "TradeRepublic: Processing '#{title}' | Subtitle: '#{subtitle}' | is_trade?: #{is_trade_result}"
    
    if is_trade_result
      Rails.logger.info "[TR Processor] Transaction id=#{traderepublic_id} is a trade."
      process_trade(traderepublic_id, title, subtitle, amount, currency, date, txn)
    else
      Rails.logger.info "[TR Processor] Transaction id=#{traderepublic_id} is NOT a trade. Importing as cash transaction."
      # Import cash transactions (dividends, interest, transfers)
      import_adapter.import_transaction(
        external_id: traderepublic_id,
        amount: amount,
        currency: currency,
        date: date,
        name: title,
        source: "traderepublic",
        notes: subtitle
      )
    end

    Rails.logger.info "TraderepublicAccount::Processor - Imported: #{title} (#{subtitle}) - #{amount} #{currency}"
  rescue => e
    Rails.logger.error "TraderepublicAccount::Processor - Error processing transaction #{txn['id']}: #{e.message}"
    Rails.logger.error e.backtrace.first(5).join("\n")
  end

  def is_trade?(text)
    return false unless text
    text_lower = text.downcase
    # Support multiple languages and variations
    # Manual orders:
    #   French: Ordre d'achat, Ordre de vente, Ordre d'achat sur stop
    #   English: Buy order, Sell order
    #   German: Kauforder, Verkaufsorder
    # Savings plans (automatic recurring purchases):
    #   French: Plan d'épargne exécuté
    #   English: Savings plan executed
    #   German: Sparplan ausgeführt
    text_lower.match?(/ordre d'achat|ordre de vente|buy order|sell order|kauforder|verkaufsorder|plan d'épargne exécuté|savings plan executed|sparplan ausgeführt/)
  end

  def process_trade(external_id, title, subtitle, amount, currency, date, txn)
    # Extraire ISIN depuis l'icon (toujours présent)
    isin = extract_isin(txn["icon"])
    Rails.logger.info "[TR Processor] process_trade: extracted ISIN=#{isin.inspect} from icon for txn id=#{external_id}"

    # 1. Chercher dans trade_details (détail transaction)
    trade_details = txn["trade_details"] || {}
    quantity_str = nil
    price_str = nil
    isin_str = nil

    # Extraction robuste depuis trade_details['sections'] (niveau 1 et imbriqué)
    if trade_details.is_a?(Hash) && trade_details["sections"].is_a?(Array)
      trade_details["sections"].each do |section|
        # Cas direct (niveau 1, Transaction)
        if section["type"] == "table" && section["title"] == "Transaction" && section["data"].is_a?(Array)
          section["data"].each do |row|
            case row["title"]
            when "Titres", "Actions"
              quantity_str ||= row.dig("detail", "text")
            when "Cours du titre", "Prix du titre"
              price_str ||= row.dig("detail", "text")
            end
          end
        end
        # Cas direct (niveau 1, tout table)
        if section["type"] == "table" && section["data"].is_a?(Array)
          section["data"].each do |row|
            case row["title"]
            when "Actions"
              quantity_str ||= row.dig("detail", "text")
            when "Prix du titre"
              price_str ||= row.dig("detail", "text")
            end
            # Cas imbriqué : row["title"] == "Transaction" && row["detail"]["action"]["payload"]["sections"]
            if row["title"] == "Transaction" && row.dig("detail", "action", "payload", "sections").is_a?(Array)
              row["detail"]["action"]["payload"]["sections"].each do |sub_section|
                next unless sub_section["type"] == "table" && sub_section["data"].is_a?(Array)
                sub_section["data"].each do |sub_row|
                  case sub_row["title"]
                  when "Actions", "Titres"
                    quantity_str ||= sub_row.dig("detail", "text")
                  when "Prix du titre", "Cours du titre"
                    price_str ||= sub_row.dig("detail", "text")
                  end
                end
              end
            end
          end
        end
      end
    end

    # Fallback : champs directs
    quantity_str ||= txn["quantity"] || txn["qty"]
    price_str ||= txn["price"] || txn["price_per_unit"]

    # ISIN : on garde la logique précédente
    isin_str = nil
    if trade_details.is_a?(Hash) && trade_details["sections"].is_a?(Array)
      trade_details["sections"].each do |section|
        if section["data"].is_a?(Hash) && section["data"]["icon"]
          possible_isin = extract_isin(section["data"]["icon"])
          isin_str ||= possible_isin if possible_isin
        end
      end
    end
    isin = isin_str if isin_str.present?

    Rails.logger.info "TradeRepublic: Processing trade #{title}"
    Rails.logger.info "TradeRepublic: Values - Qty: #{quantity_str}, Price: #{price_str}, ISIN: #{isin_str || isin}"
    Rails.logger.info "[TR Processor] process_trade: after details, ISIN=#{isin.inspect}, quantity_str=#{quantity_str.inspect}, price_str=#{price_str.inspect}"

    # Correction : s'assurer que le subtitle utilisé est bien celui du trade (issu de txn["subtitle"] si besoin)
    effective_subtitle = subtitle.presence || txn["subtitle"]
    # Détermine le type d'opération (buy/sell)
    op_type = nil
    if effective_subtitle.to_s.downcase.match?(/sell|vente|verkauf/)
      op_type = "sell"
    elsif effective_subtitle.to_s.downcase.match?(/buy|achat|kauf/)
      op_type = "buy"
    end

    quantity = parse_quantity(quantity_str) if quantity_str
    quantity = -quantity if quantity && op_type == "sell"
    price = parse_price(price_str) if price_str

    # Extract ticker and mic from instrument_details if available
    instrument_data = txn["instrument_details"]
    ticker = nil
    mic = nil
    if instrument_data.present?
      ticker_mic_pairs = extract_ticker_and_mic(instrument_data, isin)
      if ticker_mic_pairs.any?
        ticker, mic = ticker_mic_pairs.first
      end
    end

    # Si on n'a pas de quantité ou de prix, fallback transaction simple
    if isin && quantity.nil? && amount && amount != 0
      Rails.logger.warn "TradeRepublic: Cannot extract quantity/price for trade #{external_id} (#{title})"
      Rails.logger.warn "TradeRepublic: Importing as transaction instead of trade"
      Rails.logger.info "[TR Processor] process_trade: skipping trade creation for txn id=#{external_id} (missing quantity or price)"
      import_adapter.import_transaction(
        external_id: external_id,
        amount: amount,
        currency: currency,
        date: date,
        name: title,
        source: "traderepublic",
        notes: subtitle
      )
      return
    end

    # Créer le trade si toutes les infos sont là
    if isin && quantity && price
      Rails.logger.info "[TR Processor] process_trade: ready to call find_or_create_security for ISIN=#{isin.inspect}, title=#{title.inspect}, ticker=#{ticker.inspect}, mic=#{mic.inspect}"
      security = find_or_create_security(isin, title, ticker, mic)
      if security
        Rails.logger.info "[TR Processor] process_trade: got security id=#{security.id} for ISIN=#{isin}"
        Rails.logger.info "[TR Processor] TRADE IMPORT: external_id=#{external_id} qty=#{quantity} security_id=#{security.id} isin=#{isin} ticker=#{ticker} mic=#{mic} op_type=#{op_type}"
        import_adapter.import_trade(
          external_id: external_id,
          security: security,
          quantity: quantity,
          price: price,
          amount: amount,
          currency: currency,
          date: date,
          name: "#{title} - #{subtitle}",
          source: "traderepublic",
          trade_type: op_type
        )
        return
      else
        Rails.logger.error "[TR Processor] process_trade: find_or_create_security returned nil for ISIN=#{isin}"
        Rails.logger.error "TradeRepublic: Could not create security for ISIN #{isin}"
      end
    end

    # Fallback : transaction simple
    Rails.logger.warn "TradeRepublic: Falling back to transaction for #{external_id}: ISIN=#{isin}, Qty=#{quantity}, Price=#{price}"
    Rails.logger.info "[TR Processor] process_trade: fallback to cash transaction for txn id=#{external_id}"
    import_adapter.import_transaction(
      external_id: external_id,
      amount: amount,
      currency: currency,
      date: date,
      name: title,
      source: "traderepublic",
      notes: subtitle
    )
  end


  def extract_all_data(obj, result = {})
    case obj
    when Hash
      # Check if this hash looks like a data item with title/detail
      if obj["title"] && obj["detail"] && obj["detail"].is_a?(Hash) && obj["detail"]["text"]
        result[obj["title"]] = obj["detail"]["text"]
      end

      # Recursively process all values
      obj.each do |key, value|
        extract_all_data(value, result)
      end
    when Array
      obj.each do |item|
        extract_all_data(item, result)
      end
    end
    result
  end

  def parse_quantity(quantity_str)
    # quantity_str format: "3 Shares" or "0.01 BTC"
    return nil unless quantity_str

    token = quantity_str.to_s.split.first
    cleaned = token.to_s.gsub(/[^0-9.,\-+]/, "")
    return nil if cleaned.blank?

    begin
      Float(cleaned.tr(",", ".")).abs
    rescue ArgumentError, TypeError
      nil
    end
  end

  def parse_price(price_str)
    # price_str format: "€166.70" or "$500.00" - extract numeric substring and parse strictly
    return nil unless price_str

    match = price_str.to_s.match(/[+\-]?\d+(?:[.,]\d+)*/)
    return nil unless match

    cleaned = match[0].tr(",", ".")
    begin
      Float(cleaned)
    rescue ArgumentError, TypeError
      nil
    end
  end

  def extract_isin(isin_or_icon)
    return nil unless isin_or_icon
    
    # If it's already an ISIN (12 characters)
    return isin_or_icon if isin_or_icon.match?(/^[A-Z]{2}[A-Z0-9]{9}\d$/)
    
    # Extract from icon path: "logos/US0378331005/v2"
    match = isin_or_icon.match(%r{logos/([A-Z]{2}[A-Z0-9]{9}\d)/})
    match ? match[1] : nil
  end

  def find_or_create_security(isin, fallback_name = nil, ticker = nil, mic = nil)
    # Always use string and upcase safely
    safe_isin = isin.to_s.upcase
    safe_ticker = ticker.to_s.upcase if ticker
    safe_mic = mic.to_s.upcase if mic
    resolved = TradeRepublic::SecurityResolver.new(safe_isin, name: fallback_name, ticker: safe_ticker, mic: safe_mic).resolve
    return resolved if resolved
    Rails.logger.error "TradeRepublic: SecurityResolver n'a pas pu trouver ou créer de security pour ISIN=#{safe_isin}, name=#{fallback_name}, ticker=#{safe_ticker}, mic=#{safe_mic}"
    nil
  end

  # fetch_trade_details et fetch_instrument_details supprimés : tout est lu depuis raw_transactions_payload

  def extract_security_name(instrument_data)
    return nil unless instrument_data.is_a?(Hash)
    
    # Trade Republic returns instrument details with the name in different possible locations:
    # 1. Direct name field
    # 2. First exchange's nameAtExchange (most common for stocks/ETFs)
    # 3. shortName or typeNameAtExchange for other instruments
    
    # Try direct name fields first
    name = instrument_data["name"] ||
           instrument_data["shortName"] ||
           instrument_data["typeNameAtExchange"]
    
    # If no direct name, try getting from first active exchange
    if name.blank? && instrument_data["exchanges"].is_a?(Array)
      active_exchange = instrument_data["exchanges"].find { |ex| ex["active"] == true }
      exchange = active_exchange || instrument_data["exchanges"].first
      name = exchange["nameAtExchange"] if exchange
    end
    
    name&.strip
  end

  # Returns an Array of [ticker, mic] pairs ordered by relevance (active exchanges first)
  def extract_ticker_and_mic(instrument_data, isin)
    return [[isin, nil]] unless instrument_data.is_a?(Hash)

    exchanges = instrument_data["exchanges"]
    return [[isin, nil]] unless exchanges.is_a?(Array) && exchanges.any?

    # Order exchanges by active first, then the rest in their provided order
    ordered = exchanges.partition { |ex| ex["active"] == true }.flatten

    pairs = ordered.map do |ex|
      ticker = ex["symbolAtExchange"] || ex["symbol"]
      mic = ex["slug"] || ex["mic"] || ex["mic_code"]
      ticker = isin if ticker.blank?
      ticker = clean_ticker(ticker)
      [ticker, mic]
    end

    # Remove duplicates while preserving order
    pairs.map { |t, m| [t, m] }.uniq
  end

  def clean_ticker(ticker)
    return ticker unless ticker
    
    # Remove common suffixes
    # Examples: "AAPL.US" -> "AAPL", "BTCEUR.SPOT" -> "BTC/EUR" (keep as is for crypto)
    cleaned = ticker.strip
    
    # Don't clean if it looks like a crypto pair (contains /)
    return cleaned if cleaned.include?("/")
    
    # Remove .SPOT, .US, etc.
    cleaned = cleaned.split(".").first if cleaned.include?(".")
    
    cleaned
  end

  def process_holdings(account)
    payload = traderepublic_account.raw_payload
    return unless payload.is_a?(Hash)

    # The payload is wrapped in a 'raw' key by the Importer
    portfolio_data = payload["raw"] || payload

    positions = extract_positions(portfolio_data)
    
    if positions.empty?
      Rails.logger.info "TraderepublicAccount::Processor - No positions found in payload."
      Rails.logger.info "TraderepublicAccount::Processor - Calculating holdings from trades..."
      
      # Calculate holdings from trades using ForwardCalculator
      begin
        calculated_holdings = Holding::ForwardCalculator.new(account).calculate
        # Importer tous les holdings calculés, y compris qty = 0 (pour refléter la fermeture de position)
        if calculated_holdings.any?
          Holding.import!(calculated_holdings, on_duplicate_key_update: {
            conflict_target: [ :account_id, :security_id, :date, :currency ],
            columns: [ :qty, :price, :amount, :updated_at ]
          })
          Rails.logger.info "TraderepublicAccount::Processor - Saved #{calculated_holdings.size} calculated holdings (no filter)"
        else
          Rails.logger.info "TraderepublicAccount::Processor - No holdings calculated from trades"
        end
      rescue => e
        Rails.logger.error "TraderepublicAccount::Processor - Error calculating holdings from trades: #{e.message}"
        Rails.logger.error e.backtrace.first(5).join("\n")
      end
      
      return
    end

    Rails.logger.info "TraderepublicAccount::Processor - Processing #{positions.size} holdings"

    positions.each do |pos|
      process_single_holding(account, pos)
    end
  end

  def extract_positions(portfolio_data)
    return [] unless portfolio_data.is_a?(Hash)
    
    # Try to find categories in different places
    # Sometimes the payload is directly the array of categories? No, usually it's an object.
    # But sometimes it's nested in 'payload'
    
    categories = []
    
    if portfolio_data["categories"].is_a?(Array)
      categories = portfolio_data["categories"]
    elsif portfolio_data.dig("payload", "categories").is_a?(Array)
      categories = portfolio_data.dig("payload", "categories")
    elsif portfolio_data["payload"].is_a?(Hash) && portfolio_data["payload"]["categories"].is_a?(Array)
       categories = portfolio_data["payload"]["categories"]
    end
    
    Rails.logger.info "TraderepublicAccount::Processor - Categories type: #{categories.class}"
    if categories.is_a?(Array)
      Rails.logger.info "TraderepublicAccount::Processor - Categories count: #{categories.size}"
      if categories.empty?
         Rails.logger.info "TraderepublicAccount::Processor - Portfolio data keys: #{portfolio_data.keys}"
         Rails.logger.info "TraderepublicAccount::Processor - Payload keys: #{portfolio_data['payload'].keys}" if portfolio_data['payload'].is_a?(Hash)
      end
      categories.each_with_index do |cat, idx|
        Rails.logger.info "TraderepublicAccount::Processor - Category #{idx} keys: #{cat.keys rescue 'not a hash'}"
        if cat.is_a?(Hash) && cat["positions"]
          Rails.logger.info "TraderepublicAccount::Processor - Category #{idx} positions type: #{cat['positions'].class}"
        end
      end
    end

    positions = []
    categories.each do |category|
      next unless category["positions"].is_a?(Array)
      category["positions"].each { |p| positions << p }
    end
    positions
  end

  def process_single_holding(account, pos)
    isin = pos["isin"]
    name = pos["name"]
    quantity = pos["netSize"].to_f
    
    # Try to find current value
    # Trade Republic usually sends 'netValue' for the total current value of the position
    amount = pos["netValue"]&.to_f
    
    # Cost basis
    avg_buy_in = pos["averageBuyIn"]&.to_f
    cost_basis = avg_buy_in ? (quantity * avg_buy_in) : nil
    
    return unless isin && quantity
    
    if amount.nil?
      Rails.logger.warn "TraderepublicAccount::Processor - Holding #{isin} missing netValue. Keys: #{pos.keys}"
      return
    end

    security = find_or_create_security(isin, name)
    return unless security
    
    price = quantity.zero? ? 0 : (amount / quantity)

    # Prefer position currency if present, else fall back to linked account currency or account default, then final fallback to EUR
    currency = pos["currency"] || traderepublic_account.linked_account&.currency || traderepublic_account.linked_account&.default_currency || "EUR"

    import_adapter.import_holding(
      security: security,
      quantity: quantity,
      amount: amount,
      currency: currency,
      date: Date.today,
      price: price,
      cost_basis: cost_basis,
      source: "traderepublic",
      external_id: isin,
      account_provider_id: traderepublic_account.account_provider&.id
    )
  rescue => e
    Rails.logger.error "TraderepublicAccount::Processor - Error processing holding #{pos['isin']}: #{e.message}"
  end

  def update_balance(account)
    balance = traderepublic_account.current_balance
    return unless balance

    Rails.logger.info "TraderepublicAccount::Processor - Updating balance to #{balance}"

    # Update account balance
    account.update(balance: balance)
  end

  def import_adapter
    @import_adapter ||= Account::ProviderImportAdapter.new(traderepublic_account.linked_account)
  end
end
