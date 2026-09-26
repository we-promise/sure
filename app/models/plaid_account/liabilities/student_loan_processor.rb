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
      term_months: term_months,
      start_date: start_date
    )
  end

  private
    attr_reader :plaid_account

    def account
      plaid_account.current_account
    end

    # The date the loan was actually drawn down, which the payload has been
    # carrying all along. Without it an imported loan looks originated the day
    # it was imported, and everything measured from origination -- months
    # elapsed, months remaining, which instalment the borrower is on -- reads
    # the whole history of an old loan as its first month.
    #
    # Never overwrites a date already recorded: a borrower who corrected the
    # drawdown by hand knows something the provider does not, and a sync is
    # not the place to argue with them.
    def start_date
      account.loan.start_date || origination_date
    end

    # A loan within ~30 days of payoff, or one whose payoff date isn't after
    # its origination, rounds down to nothing here. nil rather than zero: a
    # term of no months is not a term, and it would make the loan look
    # amortisable over a schedule that cannot exist.
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
