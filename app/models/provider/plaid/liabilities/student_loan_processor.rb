# Port of PlaidAccount::Liabilities::StudentLoanProcessor.
class Provider::Plaid::Liabilities::StudentLoanProcessor
  def initialize(provider_account)
    @provider_account = provider_account
  end

  def process
    return unless data.present?

    provider_account.account.loan.update!(
      rate_type:        "fixed",
      interest_rate:    data["interest_rate_percentage"],
      initial_balance:  data["origination_principal_amount"],
      term_months:      term_months
    )
  end

  private
    attr_reader :provider_account

    def term_months
      return nil unless origination_date && expected_payoff_date
      ((expected_payoff_date - origination_date).to_i / 30).to_i
    end

    def origination_date
      parse_date(data["origination_date"])
    end

    def expected_payoff_date
      parse_date(data["expected_payoff_date"])
    end

    def parse_date(value)
      return value if value.is_a?(Date)
      return nil unless value.present?
      Date.parse(value.to_s)
    rescue ArgumentError
      nil
    end

    def data
      provider_account.raw_liabilities_payload&.dig("student")
    end
end
