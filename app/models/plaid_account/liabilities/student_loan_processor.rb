class PlaidAccount::Liabilities::StudentLoanProcessor
  def initialize(plaid_account)
    @plaid_account = plaid_account
  end

  def process
    return unless student_loan_data.present?

    account.loan.update!(
      rate_type: "fixed",
      interest_rate: student_loan_data["interest_rate_percentage"],
      initial_balance: student_loan_data["origination_principal_amount"],
      term_months: term_months
    )
  end

  private
    attr_reader :plaid_account

    def account
      plaid_account.current_account
    end

    # A loan within ~30 days of payoff (or, from bad upstream data, one whose
    # payoff date isn't after its origination date) rounds down to a
    # non-positive value here, which Loan's term_months validation rejects.
    # nil (rather than 0 or negative) keeps that row out of the update so the
    # rest of this sync -- interest_rate, initial_balance -- isn't rolled
    # back by an otherwise-avoidable ActiveRecord::RecordInvalid.
    def term_months
      return nil unless origination_date && expected_payoff_date

      months = ((expected_payoff_date - origination_date).to_i / 30).to_i
      months.positive? ? months : nil
    end

    def origination_date
      parse_date(student_loan_data["origination_date"])
    end

    def expected_payoff_date
      parse_date(student_loan_data["expected_payoff_date"])
    end

    def parse_date(value)
      return value if value.is_a?(Date)
      return nil unless value.present?

      Date.parse(value.to_s)
    rescue ArgumentError
      nil
    end

    def student_loan_data
      plaid_account.raw_liabilities_payload["student"]
    end
end
