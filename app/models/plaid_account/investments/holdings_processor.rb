class PlaidAccount::Investments::HoldingsProcessor
  def initialize(plaid_account, security_resolver:)
    @plaid_account = plaid_account
    @security_resolver = security_resolver
  end

  def process
    # Every holding of one sync goes on one date, the snapshot's, whatever its
    # own price date: the quantities are all as of this sync, and the readers
    # of current holdings take the provider rows on a single date.
    snapshot_date = plaid_account.holdings_snapshot_date

    holdings.each do |plaid_holding|
      resolved_security_result = security_resolver.resolve(plaid_security_id: plaid_holding["security_id"])

      next unless resolved_security_result.security.present?

      security = resolved_security_result.security

      # Parse quantity and price into BigDecimal for proper arithmetic
      quantity_bd = parse_decimal(plaid_holding["quantity"])
      price_bd = parse_decimal(plaid_holding["institution_price"])

      # Skip if essential values are missing
      next if quantity_bd.nil? || price_bd.nil?

      # Compute amount using BigDecimal arithmetic to avoid floating point drift
      amount_bd = quantity_bd * price_bd

      import_adapter.import_holding(
        security: security,
        quantity: quantity_bd,
        amount: amount_bd,
        currency: plaid_holding["iso_currency_code"] || account.currency,
        date: snapshot_date,
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
end
