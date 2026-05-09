# Port of PlaidAccount::Investments::HoldingsProcessor.
# Reads from provider_account.raw_holdings_payload, calls
# import_adapter.import_holding for each resolved holding.
class Provider::Plaid::Investments::HoldingsProcessor
  def initialize(provider_account, security_resolver:)
    @provider_account = provider_account
    @security_resolver = security_resolver
  end

  def process
    holdings.each do |plaid_holding|
      result = security_resolver.resolve(plaid_security_id: plaid_holding["security_id"])
      next unless result.security.present?

      quantity_bd = parse_decimal(plaid_holding["quantity"])
      price_bd    = parse_decimal(plaid_holding["institution_price"])
      next if quantity_bd.nil? || price_bd.nil?

      amount_bd = quantity_bd * price_bd
      holding_date = parse_date(plaid_holding["institution_price_as_of"]) || Date.current

      import_adapter.import_holding(
        security:               result.security,
        quantity:               quantity_bd,
        amount:                 amount_bd,
        currency:               plaid_holding["iso_currency_code"] || account.currency,
        date:                   holding_date,
        price:                  price_bd,
        # NB: account_provider_id intentionally omitted. holdings.account_provider_id
        # is an FK to the polymorphic account_providers table — provider_account.id
        # would point into the wrong table. Cross-provider scoping is delegated to
        # (account_id, source), which import_holding's claim/reject logic respects.
        source:                 "plaid",
        delete_future_holdings: false
      )
    end
  end

  private
    attr_reader :provider_account, :security_resolver

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end

    def account
      provider_account.account
    end

    def holdings
      provider_account.raw_holdings_payload&.dig("holdings") || []
    end

    def parse_decimal(value)
      return nil if value.nil?
      case value
      when BigDecimal then value
      when String then BigDecimal(value)
      when Numeric then BigDecimal(value.to_s)
      end
    rescue ArgumentError => e
      Rails.logger.error("Failed to parse Plaid holding decimal value: #{value.inspect} - #{e.message}")
      nil
    end

    def parse_date(value)
      return nil if value.nil?
      case value
      when Date then value
      when String then Date.parse(value)
      when Time, DateTime then value.to_date
      end
    rescue ArgumentError, TypeError => e
      Rails.logger.error("Failed to parse Plaid holding date: #{value.inspect} - #{e.message}")
      nil
    end
end
