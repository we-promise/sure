class LunchflowAccount::Investments::HoldingsProcessor
  def initialize(lunchflow_account)
    @lunchflow_account = lunchflow_account
  end

  def process
    return if holdings_data.empty?
    return unless [ "Investment", "Crypto" ].include?(account&.accountable_type)

    holdings_data.each do |lunchflow_holding|
      begin
        process_holding(lunchflow_holding)
      rescue => e
        symbol = lunchflow_holding.dig(:security, :tickerSymbol) rescue nil
        ctx = symbol.present? ? " #{symbol}" : ""
        Rails.logger.error "Error processing Lunchflow holding#{ctx}: #{e.message}"
      end
    end
  end

  private
    attr_reader :lunchflow_account

    def process_holding(lunchflow_holding)
      # Support both symbol and string keys (JSONB returns string keys)
      holding = lunchflow_holding.is_a?(Hash) ? lunchflow_holding.with_indifferent_access : {}
      security_data = (holding[:security] || {}).with_indifferent_access
      raw_data = holding[:raw] || {}

      symbol = security_data[:tickerSymbol].presence
      security_name = security_data[:name].to_s.strip

      # Extract holding ID from nested raw data (e.g., raw.quiltt.id)
      holding_id = extract_holding_id(raw_data) || generate_holding_id(holding)

      Rails.logger.debug({
        event: "lunchflow.holding.start",
        lfa_id: lunchflow_account.id,
        account_id: account&.id,
        id: holding_id,
        symbol: symbol,
        name: security_name
      }.to_json)

      # If symbol is missing but we have a name, create a synthetic ticker
      if symbol.blank? && security_name.present?
        normalized = security_name.gsub(/[^a-zA-Z0-9]/, "_").upcase.truncate(24, omission: "")
        hash_suffix = Digest::MD5.hexdigest(security_name)[0..4].upcase
        symbol = "CUSTOM:#{normalized}_#{hash_suffix}"
        Rails.logger.info("Lunchflow: using synthetic ticker #{symbol} for holding #{holding_id} (#{security_name})")
      end

      unless symbol.present?
        Rails.logger.debug({ event: "lunchflow.holding.skip", reason: "no_symbol_or_name", id: holding_id }.to_json)
        return
      end

      security = resolve_security(symbol, security_name, security_data)
      unless security.present?
        Rails.logger.debug({ event: "lunchflow.holding.skip", reason: "unresolved_security", id: holding_id, symbol: symbol }.to_json)
        return
      end

      # Parse holding data from API response
      qty = parse_decimal(holding[:quantity])
      price = parse_decimal(holding[:price])
      amount = parse_decimal(holding[:value])
      cost_basis = parse_decimal(holding[:costBasis])
      currency = holding[:currency].presence || security_data[:currency].presence || "USD"

      # Skip zero positions with no value
      if qty.to_d.zero? && amount.to_d.zero?
        Rails.logger.debug({ event: "lunchflow.holding.skip", reason: "zero_position", id: holding_id }.to_json)
        return
      end

      saved = import_adapter.import_holding(
        security: security,
        quantity: qty,
        amount: amount,
        currency: currency,
        date: Date.current,
        price: price,
        cost_basis: cost_basis,
        external_id: "lunchflow_#{holding_id}",
        account_provider_id: lunchflow_account.account_provider&.id,
        source: "lunchflow",
        delete_future_holdings: false
      )

      Rails.logger.debug({
        event: "lunchflow.holding.saved",
        account_id: account&.id,
        holding_id: saved.id,
        security_id: saved.security_id,
        qty: saved.qty.to_s,
        amount: saved.amount.to_s,
        currency: saved.currency,
        date: saved.date,
        external_id: saved.external_id
      }.to_json)
    end

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end

    def account
      lunchflow_account.current_account
    end

    def holdings_data
      lunchflow_account.raw_holdings_payload || []
    end

    def extract_holding_id(raw_data)
      # Try to find ID in nested provider data (e.g., raw.quiltt.id, raw.plaid.id, etc.)
      return nil unless raw_data.is_a?(Hash)

      raw_data.each_value do |provider_data|
        next unless provider_data.is_a?(Hash)
        id = provider_data[:id] || provider_data["id"]
        return id.to_s if id.present?
      end

      nil
    end

    def generate_holding_id(holding)
      # Generate a stable ID based on holding content
      # holding should already be with_indifferent_access from process_holding
      security = holding[:security] || {}
      content = [
        security[:tickerSymbol] || security["tickerSymbol"],
        security[:name] || security["name"],
        holding[:quantity],
        holding[:value]
      ].compact.join("-")
      Digest::MD5.hexdigest(content)[0..11]
    end

    def resolve_security(symbol, description, security_data)
      # Normalize crypto tickers to a distinct namespace
      sym = symbol.to_s.upcase
      is_crypto_account = account&.accountable_type == "Crypto"
      is_crypto_symbol = %w[BTC ETH SOL DOGE LTC BCH XRP ADA DOT AVAX].include?(sym)

      if !sym.include?(":") && (is_crypto_account || is_crypto_symbol)
        sym = "CRYPTO:#{sym}"
      end

      is_custom = sym.start_with?("CUSTOM:")

      begin
        if is_custom
          raise "Custom ticker - skipping resolver"
        end
        Security::Resolver.new(sym).resolve
      rescue => e
        Rails.logger.warn "Lunchflow: resolver failed for symbol=#{sym}: #{e.class} - #{e.message}; falling back to offline security" unless is_custom
        Security.find_or_initialize_by(ticker: sym).tap do |sec|
          sec.offline = true if sec.respond_to?(:offline) && sec.offline != true
          sec.name = description.presence if sec.name.blank? && description.present?
          sec.save! if sec.changed?
        end
      end
    end

    def parse_decimal(value)
      return BigDecimal("0") unless value.present?

      case value
      when String
        BigDecimal(value)
      when Numeric
        BigDecimal(value.to_s)
      else
        BigDecimal("0")
      end
    rescue ArgumentError => e
      Rails.logger.error "Failed to parse Lunchflow decimal value #{value}: #{e.message}"
      BigDecimal("0")
    end
end
