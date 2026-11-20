require "test_helper"

class PlaidAccount::Liabilities::CreditProcessorTest < ActiveSupport::TestCase
  setup do
    @plaid_account = plaid_accounts(:one)
    @plaid_account.update!(
      plaid_type: "credit",
      plaid_subtype: "credit_card"
    )

    @plaid_account.current_account.update!(
      accountable: CreditCard.new,
    )
  end

  test "updates credit card minimum payment and APR from Plaid data" do
    @plaid_account.update!(raw_liabilities_payload: {
      credit: {
        minimum_payment_amount: 100,
        aprs: [ { apr_percentage: 15.0 } ]
      }
    })

    processor = PlaidAccount::Liabilities::CreditProcessor.new(@plaid_account)
    processor.process

    assert_equal 100, @plaid_account.current_account.credit_card.minimum_payment
    assert_equal 15.0, @plaid_account.current_account.credit_card.apr
  end

  test "does nothing when liability data absent" do
    @plaid_account.update!(raw_liabilities_payload: {})
    processor = PlaidAccount::Liabilities::CreditProcessor.new(@plaid_account)
    processor.process

    assert_nil @plaid_account.current_account.credit_card.minimum_payment
    assert_nil @plaid_account.current_account.credit_card.apr
    assert_nil @plaid_account.current_account.credit_card.statement_close_day
    assert_nil @plaid_account.current_account.credit_card.due_day
  end

  test "records the statement cycle from the last issue date and next due date" do
    process_credit(
      minimum_payment_amount: 100,
      aprs: [ { apr_percentage: 15.0 } ],
      last_statement_issue_date: "2025-05-19",
      next_payment_due_date: "2025-06-19"
    )

    card = @plaid_account.current_account.credit_card
    assert_equal 19, card.statement_close_day
    assert_equal 19, card.due_day
  end

  test "a cycle already set by hand survives a sync" do
    process_credit(
      last_statement_issue_date: "2025-05-19",
      next_payment_due_date: "2025-06-19"
    )
    @plaid_account.current_account.credit_card.update!(statement_close_day: 3, due_day: 21)

    process_credit(
      last_statement_issue_date: "2025-07-02",
      next_payment_due_date: "2025-07-23"
    )

    card = @plaid_account.current_account.credit_card
    assert_equal 3, card.statement_close_day
    assert_equal 21, card.due_day
  end

  test "one half of the cycle can be filled in without the other" do
    process_credit(last_statement_issue_date: "2025-05-19")

    card = @plaid_account.current_account.credit_card
    assert_equal 19, card.statement_close_day
    assert_nil card.due_day
  end

  test "an unparseable statement date does not fail the sync" do
    process_credit(
      minimum_payment_amount: 100,
      aprs: [ { apr_percentage: 15.0 } ],
      last_statement_issue_date: "not-a-date"
    )

    card = @plaid_account.current_account.credit_card
    assert_nil card.statement_close_day
    assert_equal 100, card.minimum_payment
    assert_equal 15.0, card.apr
  end

  private
    def process_credit(payload)
      @plaid_account.update!(raw_liabilities_payload: { credit: payload })
      PlaidAccount::Liabilities::CreditProcessor.new(@plaid_account).process
    end
end
