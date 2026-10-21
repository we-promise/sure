class PlaidAccount::Liabilities::MortgageProcessor
  include PlaidAccount::Liabilities::LoanTermWriter

  # `as_of` is the sync's date: a variable rate change Plaid reports is dated
  # to it.
  def initialize(plaid_account, as_of: Date.current)
    @plaid_account = plaid_account
    @as_of = as_of
  end

  def process
    return unless mortgage_data.present?

    write_loan_terms(
      rate_type: mortgage_data.dig("interest_rate", "type"),
      interest_rate: mortgage_data.dig("interest_rate", "percentage")
    )
  end

  private
    attr_reader :plaid_account, :as_of

    def account
      plaid_account.current_account
    end

    def mortgage_data
      plaid_account.raw_liabilities_payload["mortgage"]
    end
end
