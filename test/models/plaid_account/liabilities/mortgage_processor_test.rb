require "test_helper"

class PlaidAccount::Liabilities::MortgageProcessorTest < ActiveSupport::TestCase
  # Rate changes are dated after it, so the loan accepts them.
  ORIGINATED = Date.new(2020, 1, 1)

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

  # A value the user corrected on the loan form is locked by
  # Account#lock_saved_attributes!, and a sync must not overwrite it.
  test "a locked interest rate is not overwritten by Plaid" do
    loan = loan_with(interest_rate: 4.5)
    loan.lock_attr!(:interest_rate)
    payload(type: "fixed", percentage: 5.2)

    process

    assert_equal 4.5, loan.reload.interest_rate.to_f, "Plaid overwrote a rate the user had locked"
    assert_equal "fixed", loan.rate_type, "the unlocked attribute beside it was not written"
  end

  test "a locked rate type is not overwritten by Plaid" do
    loan = loan_with(rate_type: "variable", interest_rate: 4.5)
    loan.lock_attr!(:rate_type)
    payload(type: "fixed", percentage: 4.5)

    process

    assert_equal "variable", loan.reload.rate_type, "Plaid overwrote a rate type the user had locked"
  end

  test "an unlocked loan is updated and Plaid is recorded as the source" do
    loan = loan_with(interest_rate: 4.5, rate_type: "variable")
    payload(type: "fixed", percentage: 5.2)

    assert_difference -> { DataEnrichment.where(enrichable: loan).count }, 2 do
      process
    end

    loan.reload
    assert_equal 5.2, loan.interest_rate.to_f
    assert_equal "fixed", loan.rate_type
    assert_equal [ "plaid" ], DataEnrichment.where(enrichable: loan).pluck(:source).uniq
  end

  # An omitted field is not a value: sending nil blanked the stored rate.
  test "a payload without a percentage leaves the stored rate alone" do
    loan = loan_with(interest_rate: 4.5)
    payload(type: "fixed")

    process

    assert_equal 4.5, loan.reload.interest_rate.to_f, "an omitted percentage blanked the stored rate"
    assert_equal "fixed", loan.rate_type, "the field the payload did carry was not written"
  end

  # The other side of that boundary: zero is a real rate, not an absent one.
  test "a rate of exactly zero is written" do
    loan = loan_with(interest_rate: 4.5)
    payload(type: "fixed", percentage: 0)

    process

    assert_equal 0.0, loan.reload.interest_rate.to_f, "an interest-free loan's zero was dropped as if absent"
  end

  test "the same payload twice records provenance once" do
    loan = loan_with(interest_rate: 4.5, rate_type: "variable")
    payload(type: "fixed", percentage: 5.2)

    assert_difference -> { DataEnrichment.where(enrichable: loan).count }, 2 do
      process
    end

    assert_no_difference -> { DataEnrichment.where(enrichable: loan).count } do
      process
    end
  end

  # Enrichable saves with `save`, not `save!`, so a refusal returns false
  # instead of raising into PlaidAccount::Processor's rescue. It must still be
  # reported. Here the refusal is Loan's own rule: a loan turned variable
  # cannot carry a rate change dated before its start date.
  test "a value the model refuses is logged rather than raised" do
    loan = loan_refusing_variable
    payload(type: "arm", percentage: 5.2)

    assert_difference -> { DebugLogEntry.where(provider_key: "plaid").count }, 1 do
      assert_nothing_raised { process }
    end

    loan.reload
    assert_equal "fixed", loan.rate_type, "a refused rate type was stored anyway"
    assert_equal 4.5, loan.interest_rate.to_f, "a refused batch was partly stored"
  end

  # Support filters /settings/debug by connection, and DebugLogEntry does not
  # derive the link from the account, so the row must carry it.
  test "a refusal is logged against the Plaid connection" do
    link = AccountProvider.create!(account: @plaid_account.current_account, provider: @plaid_account)
    loan_refusing_variable
    payload(type: "arm", percentage: 5.2)

    process

    entry = DebugLogEntry.where(provider_key: "plaid").order(:created_at).last
    assert_equal link.id, entry.account_provider_id, "the refusal was logged without its connection"
  end

  # Before the write went through Enrichable, a refusal raised into
  # PlaidAccount::Processor#process_liabilities's rescue and reached Sentry.
  # A refusal that keeps recurring must stay visible in error monitoring.
  test "a refusal is reported to Sentry" do
    loan_refusing_variable
    payload(type: "arm", percentage: 5.2)

    Sentry.expects(:capture_message).with("Plaid loan terms refused by the model", level: :warning).once

    process
  end

  # The other side: a write that changes nothing is not a refusal.
  test "a locked or unchanged write is not reported to Sentry" do
    loan = loan_with(interest_rate: 4.5, rate_type: "fixed")
    loan.lock_attr!(:interest_rate)
    payload(type: "fixed", percentage: 5.2)

    Sentry.expects(:capture_message).never

    process
  end

  # A refused write must not attribute the rejected value to Plaid. Enrichable
  # writes the DataEnrichment before it saves, and reuses the row an earlier
  # accepted write made, so only the stored value shows this.
  test "a refused value leaves the earlier provenance in place" do
    loan = loan_refusing_variable(rate_type: nil)
    writer = PlaidAccount::Liabilities::MortgageProcessor.new(@plaid_account.reload)

    writer.send(:write_loan_terms, rate_type: "fixed")
    enrichment = DataEnrichment.find_by!(enrichable: loan, attribute_name: "rate_type", source: "plaid")

    writer.send(:write_loan_terms, rate_type: "arm")

    assert_equal "fixed", enrichment.reload.value, "the refused value was recorded as Plaid's"
    assert_equal "fixed", loan.reload.rate_type
  end

  # The rollback must hold when the caller already has a transaction open;
  # a nested Rollback that merely joins it is swallowed and undoes nothing.
  test "a refused value inside a caller's transaction leaves the earlier provenance in place" do
    loan = loan_refusing_variable(rate_type: nil)
    writer = PlaidAccount::Liabilities::MortgageProcessor.new(@plaid_account.reload)
    writer.send(:write_loan_terms, rate_type: "fixed")
    enrichment = DataEnrichment.find_by!(enrichable: loan, attribute_name: "rate_type", source: "plaid")

    ActiveRecord::Base.transaction do
      writer.send(:write_loan_terms, rate_type: "arm")
    end

    assert_equal "fixed", enrichment.reload.value, "the refused value was recorded as Plaid's"
  end

  # A refusal leaves the rejected value assigned on the processor's loan. The
  # next write in the same sync would then be refused for it, losing a change
  # it had every right to.
  test "a refused value does not cost the next write its change" do
    loan = loan_refusing_variable
    writer = PlaidAccount::Liabilities::MortgageProcessor.new(@plaid_account.reload)

    writer.send(:write_loan_terms, rate_type: "arm")
    writer.send(:write_loan_terms, interest_rate: 5.2)

    loan.reload
    assert_equal 5.2, loan.interest_rate.to_f, "a valid change was refused because of an earlier rejected value"
    assert_equal "fixed", loan.rate_type
  end

  # And the errors: Enrichable returns early without saving when every
  # attribute is locked, so stale errors would be reported as a second refusal.
  test "a refusal leaves no errors behind for a locked write to report" do
    loan = loan_refusing_variable
    loan.lock_attr!(:interest_rate)
    writer = PlaidAccount::Liabilities::MortgageProcessor.new(@plaid_account.reload)

    assert_difference -> { DebugLogEntry.where(provider_key: "plaid").count }, 1 do
      writer.send(:write_loan_terms, rate_type: "arm")
      writer.send(:write_loan_terms, interest_rate: 5.2)
    end

    assert_equal 4.5, loan.reload.interest_rate.to_f
  end

  # A variable loan's rate change is a dated row, not a new base rate:
  # replacing the base rate re-prices every period before the change.
  test "a variable mortgage's rate change is dated, not overwritten" do
    loan = loan_with(interest_rate: 4.5, rate_type: "variable", start_date: ORIGINATED)
    payload(type: "variable", percentage: 5.2)

    process_as_of(Date.new(2026, 1, 15))

    loan.reload
    assert_equal 4.5, loan.interest_rate.to_f, "the base rate was overwritten"
    assert_equal({ "2026-01-15" => 5.2 }, rates(loan))
  end

  # PlaidItem::Importer#handle_plaid_error swallows ITEM_LOGIN_REQUIRED and
  # the sync still processes, so the payload is the previous sync's. A rate
  # from it is not a change the bank reported today, and dating it would
  # route around a rate the user has since corrected and locked.
  test "a rate from an import that needed a fresh login is not dated" do
    loan = loan_with(interest_rate: 4.5, rate_type: "variable", start_date: ORIGINATED)
    loan.lock_attr!(:interest_rate)
    payload(type: "variable", percentage: 5.2)
    @plaid_account.plaid_item.update!(status: :requires_update)

    process_as_of(Date.new(2026, 1, 15))

    loan.reload
    assert_equal({}, rates(loan), "a stale payload's rate was dated as a change")
    assert_equal 4.5, loan.interest_rate.to_f
  end

  # The rate is ignored, as one out of bounds is, and the rate type from the
  # same payload still lands instead of the whole write being lost.
  test "a variable rate that is not a number is ignored and the rate type still lands" do
    loan = loan_with(interest_rate: 4.5, rate_type: "fixed", start_date: ORIGINATED)
    payload(type: "variable", percentage: "n/a")

    process_as_of(Date.new(2026, 1, 15))

    loan.reload
    assert_equal "variable", loan.rate_type
    assert_equal 4.5, loan.interest_rate.to_f
    assert_equal({}, rates(loan))
  end

  test "a rate change under Plaid's own rate type is dated too" do
    loan = loan_with(interest_rate: 4.5, rate_type: "arm", start_date: ORIGINATED)
    payload(type: "arm", percentage: 5.2)

    process_as_of(Date.new(2026, 1, 15))

    loan.reload
    assert_equal 4.5, loan.interest_rate.to_f, "the base rate was overwritten"
    assert_equal({ "2026-01-15" => 5.2 }, rates(loan))
  end

  test "the dated row is keyed to the sync's date, not the clock" do
    loan = loan_with(interest_rate: 4.5, rate_type: "variable", start_date: ORIGINATED)
    payload(type: "variable", percentage: 5.2)

    travel_to Date.new(2026, 3, 1) do
      process_as_of(Date.new(2026, 1, 15))
    end

    assert_equal [ "2026-01-15" ], rates(loan.reload).keys
  end

  test "the same variable rate on the next sync adds no second row" do
    loan = loan_with(interest_rate: 4.5, rate_type: "variable", start_date: ORIGINATED)
    payload(type: "variable", percentage: 5.2)
    process_as_of(Date.new(2026, 1, 15))

    process_as_of(Date.new(2026, 1, 16))

    assert_equal({ "2026-01-15" => 5.2 }, rates(loan.reload))
  end

  test "a payload that turns a fixed loan variable dates the rate change" do
    loan = loan_with(interest_rate: 4.5, rate_type: "fixed", start_date: ORIGINATED)
    payload(type: "variable", percentage: 5.2)

    process_as_of(Date.new(2026, 1, 15))

    loan.reload
    assert_equal "variable", loan.rate_type
    assert_equal 4.5, loan.interest_rate.to_f
    assert_equal({ "2026-01-15" => 5.2 }, rates(loan))
  end

  # The negative case: a fixed loan's rate is still the base rate.
  test "a fixed mortgage's rate is still written as the base rate" do
    loan = loan_with(interest_rate: 4.5, rate_type: "fixed", start_date: ORIGINATED)
    payload(type: "fixed", percentage: 5.2)

    process_as_of(Date.new(2026, 1, 15))

    loan.reload
    assert_equal 5.2, loan.interest_rate.to_f
    assert_empty rates(loan), "a fixed loan grew a schedule"
  end

  test "a locked schedule is not written" do
    loan = loan_with(interest_rate: 4.5, rate_type: "variable", start_date: ORIGINATED)
    loan.lock_attr!(:variable_rate_schedule)
    payload(type: "variable", percentage: 5.2)

    process_as_of(Date.new(2026, 1, 15))

    loan.reload
    assert_empty rates(loan)
    assert_equal 4.5, loan.interest_rate.to_f
  end

  # The variable path is two saves: the terms, then the rate judged against the
  # loan they produce. They must land together, as the single save did, or a
  # reclassification to variable commits without the rate that came with it.
  # The rate row is refused here because it predates the loan's start date.
  test "a move to variable whose rate row is refused changes nothing" do
    loan = loan_with(interest_rate: 4.5, rate_type: "fixed", start_date: Date.new(2026, 2, 1))
    writer = PlaidAccount::Liabilities::MortgageProcessor.new(@plaid_account.reload, as_of: Date.new(2026, 1, 15))

    assert_difference -> { DebugLogEntry.where(provider_key: "plaid").count }, 1, "the refusal must still be reported" do
      writer.send(:write_loan_terms, rate_type: "variable", interest_rate: 5.2)
    end

    assert_equal "fixed", writer.send(:account).loan.rate_type,
                 "the rolled-back reclassification is still on the writer's loan in memory"
    loan.reload
    assert_equal "fixed", loan.rate_type, "the reclassification landed without its rate"
    assert_equal 4.5, loan.interest_rate.to_f
    assert_empty rates(loan)
    assert_not DataEnrichment.exists?(enrichable: loan, attribute_name: "rate_type", source: "plaid")
  end

  test "a move to variable with an acceptable rate lands both" do
    loan = loan_with(interest_rate: 4.5, rate_type: "fixed", start_date: ORIGINATED)
    writer = PlaidAccount::Liabilities::MortgageProcessor.new(@plaid_account.reload, as_of: Date.new(2026, 1, 15))

    writer.send(:write_loan_terms, rate_type: "variable", interest_rate: 5.2)

    loan.reload
    assert_equal "variable", loan.rate_type
    assert_equal({ "2026-01-15" => 5.2 }, rates(loan))
  end

  private
    def loan_with(**attrs)
      loan = @plaid_account.current_account.loan
      loan.update!(attrs)
      loan
    end

    # A loan that saves while fixed but is refused once its rate type turns
    # variable: its recorded rate change predates its start date.
    def loan_refusing_variable(rate_type: "fixed")
      loan = loan_with(rate_type: rate_type, interest_rate: 4.5, start_date: Date.new(2020, 1, 1))
      loan.update_columns(variable_rate_schedule: { "2019-06-01" => "4.0" })
      loan
    end

    def payload(**interest_rate)
      @plaid_account.update!(raw_liabilities_payload: { mortgage: { interest_rate: interest_rate } })
    end

    def process
      PlaidAccount::Liabilities::MortgageProcessor.new(@plaid_account.reload).process
    end

    def process_as_of(date)
      PlaidAccount::Liabilities::MortgageProcessor.new(@plaid_account.reload, as_of: date).process
    end

    # The schedule's value, not its stored representation.
    def rates(loan)
      (loan.variable_rate_schedule || {}).to_h { |date, rate| [ date.to_s, BigDecimal(rate.to_s).to_f ] }
    end
end
