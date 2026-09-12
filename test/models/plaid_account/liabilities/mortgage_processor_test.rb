require "test_helper"

class PlaidAccount::Liabilities::MortgageProcessorTest < ActiveSupport::TestCase
  setup do
    @plaid_account = plaid_accounts(:one)
    @plaid_account.update!(
      plaid_type: "loan",
      plaid_subtype: "mortgage"
    )

    @plaid_account.current_account.update!(accountable: Loan.new)
  end

  test "updates loan interest rate and type from Plaid data" do
    @plaid_account.update!(raw_liabilities_payload: {
      mortgage: {
        interest_rate: {
          type: "fixed",
          percentage: 4.25
        }
      }
    })

    processor = PlaidAccount::Liabilities::MortgageProcessor.new(@plaid_account)
    processor.process

    loan = @plaid_account.current_account.loan

    assert_equal "fixed", loan.rate_type
    assert_equal 4.25, loan.interest_rate
  end

  # #100 decision 8: Plaid's own vocabulary ("arm") is written through as-is,
  # and the loan it lands on must still get a schedule.
  test "a Plaid rate type outside the form's vocabulary still yields a schedule" do
    @plaid_account.current_account.update!(balance: 250_000, accountable: Loan.new(term_months: 360))
    @plaid_account.update!(raw_liabilities_payload: {
      mortgage: {
        interest_rate: {
          type: "arm",
          percentage: 5.1
        }
      }
    })

    PlaidAccount::Liabilities::MortgageProcessor.new(@plaid_account).process

    loan = @plaid_account.current_account.reload.loan

    assert_equal "arm", loan.rate_type
    assert loan.variable_rate_type?
    assert_not_empty loan.amortization_schedule.payments
  end

  test "does nothing when mortgage data absent" do
    @plaid_account.update!(raw_liabilities_payload: {})

    processor = PlaidAccount::Liabilities::MortgageProcessor.new(@plaid_account)
    processor.process

    loan = @plaid_account.current_account.loan

    assert_nil loan.rate_type
    assert_nil loan.interest_rate
  end
end
