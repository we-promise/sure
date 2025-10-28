class PlaidAccount::Liabilities::CreditProcessor
  def initialize(plaid_account)
    @plaid_account = plaid_account
  end

  def process
    return unless credit_data.present?

    import_adapter.update_accountable_attributes(
      attributes: {
        minimum_payment: credit_data.dig("minimum_payment_amount"),
        apr: credit_data.dig("aprs", 0, "apr_percentage")
      },
      source: "plaid"
    )
  end

  private
    attr_reader :plaid_account

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end

    def account
      plaid_account.current_account
    end

    def credit_data
      plaid_account.raw_liabilities_payload["credit"]
    end
end
