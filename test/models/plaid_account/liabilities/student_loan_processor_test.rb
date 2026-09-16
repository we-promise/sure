require "test_helper"

class PlaidAccount::Liabilities::StudentLoanProcessorTest < ActiveSupport::TestCase
  setup do
    @plaid_account = plaid_accounts(:one)
    @plaid_account.update!(
      plaid_type: "loan",
      plaid_subtype: "student"
    )

    # Change the underlying accountable to a Loan so the helper method `loan` is available
    @plaid_account.current_account.update!(accountable: Loan.new)
  end

  test "updates loan details including term months from Plaid data" do
    @plaid_account.update!(raw_liabilities_payload: {
      student: {
        interest_rate_percentage: 5.5,
        origination_principal_amount: 20000,
        origination_date: Date.new(2020, 1, 1),
        expected_payoff_date: Date.new(2022, 1, 1)
      }
    })

    processor = PlaidAccount::Liabilities::StudentLoanProcessor.new(@plaid_account)
    processor.process

    loan = @plaid_account.current_account.loan

    assert_equal "fixed", loan.rate_type
    assert_equal 5.5, loan.interest_rate
    assert_equal 20000, loan.initial_balance
    assert_equal 24, loan.term_months
  end

  # The payload has carried the drawdown date all along and nothing wrote it
  # down, so every imported loan looked originated on import day.
  test "records the provider's origination date as the loan's start date" do
    @plaid_account.update!(raw_liabilities_payload: {
      student: {
        interest_rate_percentage: 5.5,
        origination_principal_amount: 20000,
        origination_date: Date.new(2020, 1, 1),
        expected_payoff_date: Date.new(2022, 1, 1)
      }
    })

    PlaidAccount::Liabilities::StudentLoanProcessor.new(@plaid_account).process

    assert_equal Date.new(2020, 1, 1), @plaid_account.current_account.loan.start_date
  end

  # A borrower who corrected the drawdown by hand knows something the provider
  # does not.
  test "a start date already recorded is not overwritten by the sync" do
    @plaid_account.current_account.loan.update!(start_date: Date.new(2019, 3, 4))
    @plaid_account.update!(raw_liabilities_payload: {
      student: {
        interest_rate_percentage: 5.5,
        origination_principal_amount: 20000,
        origination_date: Date.new(2020, 1, 1),
        expected_payoff_date: Date.new(2022, 1, 1)
      }
    })

    PlaidAccount::Liabilities::StudentLoanProcessor.new(@plaid_account).process

    assert_equal Date.new(2019, 3, 4), @plaid_account.current_account.loan.start_date
  end

  # Under 30 days between origination and payoff rounds to zero months. Stored
  # as nil, because a term of no months is not a term -- and the rest of the
  # payload must still land rather than being lost with it.
  test "a term of under a month is no term, and does not cost the rest of the sync" do
    @plaid_account.update!(raw_liabilities_payload: {
      student: {
        interest_rate_percentage: 6.25,
        origination_principal_amount: 900,
        origination_date: Date.new(2026, 1, 1),
        expected_payoff_date: Date.new(2026, 1, 20)
      }
    })

    PlaidAccount::Liabilities::StudentLoanProcessor.new(@plaid_account).process

    loan = @plaid_account.current_account.loan

    assert_nil loan.term_months
    assert_equal 6.25, loan.interest_rate, "the rest of the payload still lands"
    assert_equal 900, loan.initial_balance
  end

  test "handles missing payoff dates gracefully" do
    @plaid_account.update!(raw_liabilities_payload: {
      student: {
        interest_rate_percentage: 4.8,
        origination_principal_amount: 15000,
        origination_date: Date.new(2021, 6, 1)
        # expected_payoff_date omitted
      }
    })

    processor = PlaidAccount::Liabilities::StudentLoanProcessor.new(@plaid_account)
    processor.process

    loan = @plaid_account.current_account.loan

    assert_nil loan.term_months
    assert_equal 4.8, loan.interest_rate
    assert_equal 15000, loan.initial_balance
  end

  test "does nothing when loan data absent" do
    @plaid_account.update!(raw_liabilities_payload: {})

    processor = PlaidAccount::Liabilities::StudentLoanProcessor.new(@plaid_account)
    processor.process

    loan = @plaid_account.current_account.loan

    assert_nil loan.interest_rate
    assert_nil loan.initial_balance
    assert_nil loan.term_months
  end
end
