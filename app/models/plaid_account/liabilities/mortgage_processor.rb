class PlaidAccount::Liabilities::MortgageProcessor
  def initialize(plaid_account)
    @plaid_account = plaid_account
  end

  def process
    return unless mortgage_data.present?

    account.loan.update!(
      rate_type: rate_type,
      interest_rate: mortgage_data.dig("interest_rate", "percentage")
    )
  end

  private
    attr_reader :plaid_account

    def account
      plaid_account.current_account
    end

    def mortgage_data
      plaid_account.raw_liabilities_payload["mortgage"]
    end

    # Plaid's raw value passed straight into Loan#rate_type's inclusion
    # validation would fail the whole update! (rolling back interest_rate too)
    # for any casing/value Plaid sends outside the exact allow-list. Normalize
    # case and clamp anything unrecognized to nil, which the validation
    # already permits.
    def rate_type
      raw = mortgage_data.dig("interest_rate", "type")
      normalized = raw.to_s.strip.downcase
      normalized if Loan::RATE_TYPES.include?(normalized)
    end
end
