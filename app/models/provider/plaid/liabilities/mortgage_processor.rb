# Port of PlaidAccount::Liabilities::MortgageProcessor.
class Provider::Plaid::Liabilities::MortgageProcessor
  def initialize(provider_account)
    @provider_account = provider_account
  end

  def process
    return unless mortgage_data.present?

    provider_account.account.loan.update!(
      rate_type:     mortgage_data.dig("interest_rate", "type"),
      interest_rate: mortgage_data.dig("interest_rate", "percentage")
    )
  end

  private
    attr_reader :provider_account

    def mortgage_data
      provider_account.raw_liabilities_payload&.dig("mortgage")
    end
end
