class SimplefinAccount::Investments::HoldingsProcessor
  def initialize(simplefin_account)
    @simplefin_account = simplefin_account
  end

  def process
    return if holdings_data.empty?
    return unless [ "Investment", "Crypto" ].include?(account&.accountable_type)

    holdings_data.each do |simplefin_holding|
      begin
        symbol = simplefin_holding["symbol"].presence
        holding_id = simplefin_holding["id"]
        description = simplefin_holding["description"].to_s.strip

        Rails.logger.debug({ event: "simplefin.holding.start", sfa_id: simplefin_account.id, account_id: account&.id, id: holding_id, symbol: symbol, raw: simplefin_holding }.to_json)

        unless holding_id.present?
          Rails.logger.debug({ event: "simplefin.holding.skip", reason: "missing_id", id: holding_id, symbol: symbol }.to_json)
          next
        end

        # If symbol is missing but we have a description, create a synthetic ticker
        # This allows tracking holdings like 401k funds that don't have standard symbols
        # Append a hash suffix to ensure uniqueness for similar descriptions
        if symbol.blank? && description.present?
          normalized = description.gsub(/[^a-zA-Z0-9]/, "_").upcase.truncate(24, omission: "")
          hash_suffix = Digest::MD5.hexdigest(description)[0..4].upcase
          symbol = "CUSTOM:#{normalized}_#{hash_suffix}"
          Rails.logger.info("SimpleFin: using synthetic ticker #{symbol} for holding #{holding_id} (#{description})")
        end

        unless symbol.present?
          Rails.logger.debug({ event: "simplefin.holding.skip", reason: "no_symbol_or_description", id: holding_id }.to_json)
          next
        end

        security = resolve_security(symbol, simplefin_holding["description"])
        unless security.present?
          Rails.logger.debug({ event: "simplefin.holding.skip", reason: "unresolved_security", id: holding_id, symbol: symbol }.to_json)
          next
        end

        # Parse provider data with robust fallbacks across SimpleFin sources
        qty = parse_decimal(any_of(simplefin_holding, %w[shares quantity qty units]))
        market_value = parse_decimal(any_of(simplefin_holding, %w[market_value value current_value]))
        cost_basis = parse_decimal(any_of(simplefin_holding, %w[cost_basis basis total_cost]))

        # Derive price from market_value when possible; otherwise fall back to any price field
        fallback_price = parse_decimal(any_of(simplefin_holding, %w[purchase_price price unit_price average_cost avg_cost]))
        price = if qty > 0 && market_value > 0
          market_value / qty
        else
          fallback_price || 0
        end

        # Compute an amount we can persist (some providers omit market_value)
        computed_amount = if market_value > 0
          market_value
        elsif qty > 0 && price > 0
          qty * price
        else
          0
        end

        # SimpleFIN holdings represent a current snapshot, not historical positions.
        # Always use today's date regardless of the `created` timestamp (which is when
        # the holding was first seen by SimpleFIN, not when we observed it).
        holding_date = Date.current

        # Skip zero positions with no value to avoid invisible rows
        next if qty.to_d.zero? && computed_amount.to_d.zero?

        saved = import_adapter.import_holding(
          security: security,
          quantity: qty,
          amount: computed_amount,
          currency: simplefin_holding["currency"].presence || "USD",
          date: holding_date,
          price: price,
          cost_basis: cost_basis,
          external_id: "simplefin_#{holding_id}",
          account_provider_id: simplefin_account.account_provider&.id,
          source: "simplefin",
          delete_future_holdings: false  # SimpleFin tracks each holding uniquely
        )

        Rails.logger.debug({ event: "simplefin.holding.saved", account_id: account&.id, holding_id: saved.id, security_id: saved.security_id, qty: saved.qty.to_s, amount: saved.amount.to_s, currency: saved.currency, date: saved.date, external_id: saved.external_id }.to_json)
      rescue => e
        ctx = (defined?(symbol) && symbol.present?) ? " #{symbol}" : ""
        Rails.logger.error "Error processing SimpleFin holding#{ctx}: #{e.message}"
      end
    end
  end

  private
    attr_reader :simplefin_account

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end

    def account
      simplefin_account.current_account
    end

    def holdings_data
      # Use the dedicated raw_holdings_payload field
      simplefin_account.raw_holdings_payload || []
    end

    def resolve_security(symbol, description)
      # Normalize crypto tickers to a distinct namespace so they don't collide with equities
      sym = symbol.to_s.upcase
      is_crypto_account = account&.accountable_type == "Crypto" || simplefin_account.name.to_s.downcase.include?("crypto")
      is_crypto_symbol  = %w[BTC ETH SOL DOGE LTC BCH].include?(sym)
      mentions_crypto   = description.to_s.downcase.include?("crypto")

      if !sym.include?(":") && (is_crypto_account || is_crypto_symbol || mentions_crypto)
        sym = "CRYPTO:#{sym}"
      end

      # Custom tickers (from holdings without symbols) should always be offline
      is_custom = sym.start_with?("CUSTOM:")

      # Use Security::Resolver to find or create the security, but be resilient
      begin
        if is_custom
          # Skip resolver for custom tickers - create offline security directly
          raise "Custom ticker - skipping resolver"
        end
        Security::Resolver.new(sym).resolve
      rescue => e
        # If provider search fails or any unexpected error occurs, fall back to an offline security
        Rails.logger.warn "SimpleFin: resolver failed for symbol=#{sym}: #{e.class} - #{e.message}; falling back to offline security" unless is_custom
        Security.find_or_initialize_by(ticker: sym).tap do |sec|
          sec.offline = true if sec.respond_to?(:offline) && sec.offline != true
          sec.name = description.presence if sec.name.blank? && description.present?
          sec.save! if sec.changed?
        end
      end
    end

    def parse_holding_date(created_timestamp)
      return nil unless created_timestamp

      case created_timestamp
      when Integer
        Time.at(created_timestamp).to_date
      when String
        Date.parse(created_timestamp)
      else
        nil
      end
    rescue ArgumentError => e
      Rails.logger.error "Failed to parse SimpleFin holding date #{created_timestamp}: #{e.message}"
      nil
    end

    # Returns the first non-empty value for any of the provided keys in the given hash
    def any_of(hash, keys)
      return nil unless hash.respond_to?(:[])
      Array(keys).each do |k|
        # Support symbol or string keys
        v = hash[k]
        v = hash[k.to_s] if v.nil?
        v = hash[k.to_sym] if v.nil?
        return v if !v.nil? && v.to_s.strip != ""
      end
      nil
    end

    def parse_decimal(value)
      return 0 unless value.present?

      case value
      when String
        BigDecimal(value)
      when Numeric
        BigDecimal(value.to_s)
      else
        BigDecimal("0")
      end
    rescue ArgumentError => e
      Rails.logger.error "Failed to parse SimpleFin decimal value #{value}: #{e.message}"
      BigDecimal("0")
    end
end
