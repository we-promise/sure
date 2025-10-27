class PlaidAccount::Investments::HoldingsProcessor
  def initialize(plaid_account, security_resolver:)
    @plaid_account = plaid_account
    @security_resolver = security_resolver
  end

  def process
    holdings.each do |plaid_holding|
      resolved_security_result = security_resolver.resolve(plaid_security_id: plaid_holding["security_id"])

      next unless resolved_security_result.security.present?

      security = resolved_security_result.security
      holding_date = plaid_holding["institution_price_as_of"] || Date.current
      quantity = plaid_holding["quantity"]
      price = plaid_holding["institution_price"]

      import_adapter.import_holding(
        security: security,
        quantity: quantity,
        amount: quantity * price,
        currency: plaid_holding["iso_currency_code"],
        date: holding_date,
        price: price,
        source: "plaid",
        delete_future_holdings: true  # Plaid deletes future holdings
      )
    end
  end

  private
    attr_reader :plaid_account, :security_resolver

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end

    def account
      plaid_account.account
    end

    def holdings
      plaid_account.raw_investments_payload["holdings"] || []
    end
end
