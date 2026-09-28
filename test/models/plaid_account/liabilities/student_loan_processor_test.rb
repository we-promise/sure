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

  # A payoff less than a month after origination is zero months. Stored
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

  # Counted in calendar months, not 30-day blocks: thirty years is 10,958 days,
  # which divided by 30 made a 360-month loan a 365-month one and put its payoff
  # date and current instalment five months out.
  test "the term is counted in calendar months" do
    @plaid_account.update!(raw_liabilities_payload: {
      student: {
        interest_rate_percentage: 5.5,
        origination_principal_amount: 20000,
        origination_date: Date.new(2000, 1, 1),
        expected_payoff_date: Date.new(2030, 1, 1)
      }
    })

    PlaidAccount::Liabilities::StudentLoanProcessor.new(@plaid_account).process

    assert_equal 360, @plaid_account.current_account.loan.term_months
  end

  # Both sides of the boundary: a month counts once it has been served in full,
  # which is how Loan#months_elapsed counts the same loan's progress.
  test "a term month counts once it is served in full" do
    [ [ Date.new(2026, 2, 24), nil ], [ Date.new(2026, 2, 25), 1 ], [ Date.new(2027, 1, 24), 11 ] ].each do |payoff, expected|
      @plaid_account.update!(raw_liabilities_payload: {
        student: {
          interest_rate_percentage: 5.5,
          origination_principal_amount: 20000,
          origination_date: Date.new(2026, 1, 25),
          expected_payoff_date: payoff
        }
      })

      PlaidAccount::Liabilities::StudentLoanProcessor.new(@plaid_account).process

      assert_equal expected, @plaid_account.current_account.loan.reload.term_months, "payoff on #{payoff}"
    end
  end

  # A loan cannot start in the future (Loan validates it), and a provider date
  # that says otherwise must not fail the whole liabilities sync with it. The
  # date is left unrecorded and the rest of the payload lands.
  test "a future origination date is not recorded and does not fail the sync" do
    travel_to Date.new(2026, 1, 10) do
      @plaid_account.update!(raw_liabilities_payload: {
        student: {
          interest_rate_percentage: 5.5,
          origination_principal_amount: 20000,
          origination_date: Date.new(2026, 3, 1),
          expected_payoff_date: Date.new(2036, 3, 1)
        }
      })

      PlaidAccount::Liabilities::StudentLoanProcessor.new(@plaid_account).process

      loan = @plaid_account.current_account.loan.reload
      assert_nil loan.start_date
      assert_equal 5.5, loan.interest_rate, "the rest of the payload still lands"
      assert_equal 120, loan.term_months
    end
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
