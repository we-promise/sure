class SimplefinAccount::Investments::HoldingsProcessor
  def initialize(simplefin_account)
    @simplefin_account = simplefin_account
  end

  def process
    return if holdings_data.empty?
    return unless account&.accountable_type == "Investment"

    holdings_data.each do |simplefin_holding|
      begin
        symbol = simplefin_holding["symbol"]
        holding_id = simplefin_holding["id"]

        next unless symbol.present? && holding_id.present?

        security = resolve_security(symbol, simplefin_holding["description"])
        next unless security.present?

        # Parse all the data SimpleFin provides
        qty = parse_decimal(simplefin_holding["shares"])
        market_value = parse_decimal(simplefin_holding["market_value"])
        cost_basis = parse_decimal(simplefin_holding["cost_basis"])

        # Calculate price from market_value if we have shares, fallback to purchase_price
        price = if qty > 0 && market_value > 0
          market_value / qty
        else
          parse_decimal(simplefin_holding["purchase_price"]) || 0
        end

        # Use the created timestamp as the holding date, fallback to current date
        holding_date = parse_holding_date(simplefin_holding["created"]) || Date.current

        import_adapter.import_holding(
          security: security,
          quantity: qty,
          amount: market_value,
          currency: simplefin_holding["currency"] || "USD",
          date: holding_date,
          price: price,
          cost_basis: cost_basis,
          external_id: "simplefin_#{holding_id}",
          account_provider_id: simplefin_account.account_provider&.id,
          source: "simplefin",
          delete_future_holdings: false  # SimpleFin tracks each holding uniquely
        )
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
      # Use Security::Resolver to find or create the security
      Security::Resolver.new(symbol).resolve
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
