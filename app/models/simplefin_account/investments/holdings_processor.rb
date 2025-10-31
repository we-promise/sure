class SimplefinAccount::Investments::HoldingsProcessor
  def initialize(simplefin_account)
    @simplefin_account = simplefin_account
  end

  def process
    return if holdings_data.empty?
    return unless [ "Investment", "Crypto" ].include?(account&.accountable_type)

    holdings_data.each do |simplefin_holding|
      begin
        data = simplefin_holding.with_indifferent_access
        symbol = data[:symbol]
        holding_id = data[:id]

        if ENV["SURE_LOG_SIMPLEFIN_HOLDINGS"].present?
          Rails.logger.info({ event: "simplefin.holding.start", sfa_id: simplefin_account.id, account_id: account&.id, id: holding_id, symbol: symbol, raw: data }.to_json)
        end

        unless symbol.present? && holding_id.present?
          if ENV["SURE_LOG_SIMPLEFIN_HOLDINGS"].present?
            Rails.logger.info({ event: "simplefin.holding.skip", reason: "missing_symbol_or_id", id: holding_id, symbol: symbol }.to_json)
          end
          next
        end

        security = resolve_security(symbol, simplefin_holding["description"])
        unless security.present?
          if ENV["SURE_LOG_SIMPLEFIN_HOLDINGS"].present?
            Rails.logger.info({ event: "simplefin.holding.skip", reason: "unresolved_security", id: holding_id, symbol: symbol }.to_json)
          end
          next
        end

        # Parse provider data with robust fallbacks across SimpleFin sources
        qty = parse_decimal(any_of(data, %w[shares quantity qty units]))
        market_value = parse_decimal(any_of(data, %w[market_value value current_value]))
        cost_basis = parse_decimal(any_of(data, %w[cost_basis basis total_cost]))

        # Derive price from market_value when possible; otherwise fall back to any price field
        fallback_price = parse_decimal(any_of(data, %w[purchase_price price unit_price average_cost avg_cost]))
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

        # Use best-known date: created -> updated_at -> as_of -> date -> today
        holding_date = parse_holding_date(any_of(data, %w[created updated_at as_of date])) || Date.current

        # Currency defaults to account currency then USD
        currency = (data[:currency].presence || account.currency.presence || "USD").to_s.upcase

        # Skip zero positions with no value to avoid invisible rows
        next if qty.to_d.zero? && computed_amount.to_d.zero?

        saved = import_adapter.import_holding(
          security: security,
          quantity: qty,
          amount: computed_amount,
          currency: currency,
          date: holding_date,
          price: price,
          cost_basis: cost_basis,
          external_id: "simplefin_#{holding_id}",
          account_provider_id: simplefin_account.account_provider&.id,
          source: "simplefin",
          delete_future_holdings: false  # SimpleFin tracks each holding uniquely
        )

        if ENV["SURE_LOG_SIMPLEFIN_HOLDINGS"].present?
          Rails.logger.info({ event: "simplefin.holding.saved", account_id: account&.id, holding_id: saved.id, security_id: saved.security_id, qty: saved.qty.to_s, amount: saved.amount.to_s, currency: saved.currency, date: saved.date, external_id: saved.external_id }.to_json)
        end
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
      # Use Security::Resolver to find or create the security
      Security::Resolver.new(sym).resolve
    rescue ArgumentError => e
      Rails.logger.error "Failed to resolve SimpleFin security #{symbol}: #{e.message}"
      nil
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
