# Port of PlaidAccount::Liabilities::CreditProcessor.
class Provider::Plaid::Liabilities::CreditProcessor
  def initialize(provider_account)
    @provider_account = provider_account
  end

  def process
    return unless credit_data.present?

    import_adapter.update_accountable_attributes(
      attributes: {
        minimum_payment: credit_data["minimum_payment_amount"],
        apr:             credit_data.dig("aprs", 0, "apr_percentage")
      },
      source: "plaid"
    )
  end

  private
    attr_reader :provider_account

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(provider_account.account)
    end

    def credit_data
      provider_account.raw_liabilities_payload&.dig("credit")
    end
end
