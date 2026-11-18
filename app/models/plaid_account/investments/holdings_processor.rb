class PlaidAccount::Investments::HoldingsProcessor
  def initialize(plaid_account, security_resolver:, currency: nil)
    @plaid_account = plaid_account
    @security_resolver = security_resolver
    @currency = currency
  end

  def process
    holdings.each do |plaid_holding|
      resolved_security_result = security_resolver.resolve(plaid_security_id: plaid_holding["security_id"])

      next unless resolved_security_result.security.present?

      security = resolved_security_result.security

      # Parse quantity and price into BigDecimal for proper arithmetic
      quantity_bd = parse_decimal(plaid_holding["quantity"])
      price_bd = parse_decimal(plaid_holding["institution_price"])

      # Skip if essential values are missing
      next if quantity_bd.nil? || price_bd.nil?

      # Institutions quote some fixed income as a percent of par and some as a
      # fraction of it, so quantity * institution_price can be 100x the
      # position. institution_value is the position's value either way.
      value_bd = parse_decimal(plaid_holding["institution_value"])
      if value_bd&.nonzero? && quantity_bd.nonzero?
        amount_bd = value_bd
        price_bd = value_bd / quantity_bd
      else
        amount_bd = quantity_bd * price_bd
      end

      # Normalize date - handle string, Date, or nil
      holding_date = parse_date(plaid_holding["institution_price_as_of"]) || Date.current

      import_adapter.import_holding(
        security: security,
        quantity: quantity_bd,
        amount: amount_bd,
        currency: plaid_holding["iso_currency_code"] || @currency || account.currency,
        date: holding_date,
        price: price_bd,
        account_provider_id: plaid_account.account_provider&.id,
        source: "plaid",
        delete_future_holdings: false  # Plaid doesn't allow holdings deletion
      )
    end
  end

  private
    attr_reader :plaid_account, :security_resolver

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end

    def account
      plaid_account.current_account
    end

    def holdings
      plaid_account.raw_holdings_payload&.[]("holdings") || []
    end

    def parse_decimal(value)
      return nil if value.nil?

      case value
      when BigDecimal
        value
      when String
        BigDecimal(value)
      when Numeric
        BigDecimal(value.to_s)
      else
        nil
      end
    rescue ArgumentError => e
      Rails.logger.error("Failed to parse Plaid holding decimal value: #{value.inspect} - #{e.message}")
      nil
    end

    def parse_date(date_value)
      return nil if date_value.nil?

      case date_value
      when Date
        date_value
      when String
        Date.parse(date_value)
      when Time, DateTime
        date_value.to_date
      else
        nil
      end
    rescue ArgumentError, TypeError => e
      Rails.logger.error("Failed to parse Plaid holding date: #{date_value.inspect} - #{e.message}")
      nil
    end
end
