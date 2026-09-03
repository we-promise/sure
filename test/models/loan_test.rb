require "test_helper"

class LoanTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  test "rejects invalid subtype" do
    loan = Loan.new(subtype: "invalid")

    assert_not loan.valid?
    assert_includes loan.errors[:subtype], "is not included in the list"
  end

  test "rejects malformed variable rate schedule entries" do
    loan = Loan.new(variable_rate_schedule: { "not-a-date" => "not-a-rate" })

    assert_not loan.valid?
    assert_includes loan.errors[:variable_rate_schedule], "contains an invalid effective date"
    assert_includes loan.errors[:variable_rate_schedule], "contains a non-numeric rate"
  end

  test "rejects a variable rate schedule entry outside the supported range" do
    loan = Loan.new(variable_rate_schedule: { "2027-01-01" => -1, "2028-01-01" => 250 })

    assert_not loan.valid?
    assert_includes loan.errors[:variable_rate_schedule], "contains a rate outside the supported 0-100 range"
  end

  test "quantizes variable rate schedule entries to 3 decimal places" do
    loan = Loan.new(rate_type: "variable", variable_rate_schedule: { "2027-01-01" => 5.123456 })
    assert loan.valid?
    assert_equal 5.123, loan.variable_rate_schedule["2027-01-01"]
  end

  test "rejects term months outside the supported range" do
    loan = Loan.new(term_months: 0)
    assert_not loan.valid?
    assert_includes loan.errors[:term_months], "must be greater than 0"

    loan = Loan.new(term_months: Loan::MAX_TERM_MONTHS + 1)
    assert_not loan.valid?
    assert_includes loan.errors[:term_months], "must be less than or equal to #{Loan::MAX_TERM_MONTHS}"
  end

  test "rejects an interest rate outside the supported range" do
    loan = Loan.new(interest_rate: -1)
    assert_not loan.valid?
    assert_includes loan.errors[:interest_rate], "must be greater than or equal to 0"

    loan = Loan.new(interest_rate: 101)
    assert_not loan.valid?
    assert_includes loan.errors[:interest_rate], "must be less than or equal to 100"
  end

  test "calculates correct monthly payment for fixed rate loan" do
    loan_account = Account.create! \
      family: families(:dylan_family),
      name: "Mortgage Loan",
      balance: 500000,
      currency: "USD",
      accountable: Loan.create!(
        subtype: "mortgage",
        interest_rate: 3.5,
        term_months: 360,
        rate_type: "fixed"
      )

    assert_equal BigDecimal("2245.22"), loan_account.loan.monthly_payment.amount
  end

  test "amortization_schedule returns valid schedule for fixed rate loan" do
    loan_account = Account.create! \
      family: families(:dylan_family),
      name: "Mortgage Loan",
      balance: 500000,
      currency: "USD",
      accountable: Loan.create!(
        subtype: "mortgage",
        interest_rate: 3.5,
        term_months: 360,
        rate_type: "fixed"
      )

    schedule = loan_account.loan.amortization_schedule
    assert schedule.amortizable?
    assert_equal 360, schedule.payment_count
    assert schedule.payoff_date.present?
    assert schedule.total_interest.positive?
    assert schedule.monthly_payment.positive?
  end

  test "amortization_schedule is amortizable for variable rate loan with a base rate" do
    loan_account = Account.create! \
      family: families(:dylan_family),
      name: "Variable Rate Loan",
      balance: 500000,
      currency: "USD",
      accountable: Loan.create!(
        subtype: "line_of_credit",
        interest_rate: 3.5,
        term_months: 360,
        rate_type: "variable"
      )

    schedule = loan_account.loan.amortization_schedule
    assert schedule.amortizable?
  end

  test "amortization_schedule not amortizable for loan without an interest rate" do
    loan_account = Account.create! \
      family: families(:dylan_family),
      name: "No Rate Loan",
      balance: 500000,
      currency: "USD",
      accountable: Loan.create!(
        subtype: "other",
        interest_rate: nil,
        term_months: 360,
        rate_type: "fixed"
      )

    schedule = loan_account.loan.amortization_schedule
    assert_not schedule.amortizable?
  end

  test "amortizable? is false before the loan has an account" do
    loan = Loan.create!(
      subtype: "mortgage",
      interest_rate: 3.5,
      term_months: 360,
      rate_type: "fixed"
    )

    assert_nil loan.account
    assert_not loan.amortizable?
    assert_equal 0, loan.amortizations.count
  end

  test "an amortization rebuild is enqueued (not run inline) when terms change" do
    loan_account = Account.create! \
      family: families(:dylan_family),
      name: "Mortgage Loan",
      balance: 500000,
      currency: "USD",
      accountable: Loan.create!(
        subtype: "mortgage",
        interest_rate: 3.5,
        term_months: 360,
        rate_type: "fixed"
      )

    loan = loan_account.loan
    assert_equal 0, loan.amortizations.count

    assert_enqueued_with(job: LoanAmortizationRebuildJob, args: [ loan.id ]) do
      loan.update!(interest_rate: 4.0)
    end
    assert_equal 0, loan.amortizations.count, "the save itself must not synchronously build the schedule"

    perform_enqueued_jobs
    assert_equal 360, loan.amortizations.count
  end

  test "clears the persisted schedule when a loan becomes non-amortizable" do
    loan_account = Account.create! \
      family: families(:dylan_family),
      name: "Mortgage Loan",
      balance: 500000,
      currency: "USD",
      accountable: Loan.create!(
        subtype: "mortgage",
        interest_rate: 3.5,
        term_months: 360,
        rate_type: "fixed"
      )

    loan = loan_account.loan
    loan.rebuild_amortization_schedule
    assert_equal 360, loan.amortizations.count

    perform_enqueued_jobs do
      loan.update!(interest_rate: nil)
    end

    assert_equal 0, loan.amortizations.count
  end

  test "rebuilds the persisted schedule when Account-derived inputs change" do
    loan_account = Account.create! \
      family: families(:dylan_family),
      name: "Mortgage Loan",
      balance: 500000,
      currency: "USD",
      accountable: Loan.create!(
        subtype: "mortgage",
        interest_rate: 3.5,
        term_months: 360,
        rate_type: "fixed"
      )

    loan = loan_account.loan
    loan.ensure_amortization_schedule_current!
    assert_equal 360, loan.amortizations.count
    original_signature = loan.amortizations.ordered.first.schedule_signature

    loan_account.update!(balance: 450000)
    loan.ensure_amortization_schedule_current!

    assert_not_equal original_signature, loan.amortizations.ordered.first.schedule_signature
    assert_equal BigDecimal("450000"), loan.amortizations.ordered.first.beginning_balance
  end

  test "ensure_amortization_schedule_current! does not duplicate rows when called repeatedly" do
    loan_account = Account.create! \
      family: families(:dylan_family),
      name: "Mortgage Loan",
      balance: 500000,
      currency: "USD",
      accountable: Loan.create!(
        subtype: "mortgage",
        interest_rate: 3.5,
        term_months: 360,
        rate_type: "fixed"
      )

    loan = loan_account.loan
    assert_equal 0, loan.amortizations.count

    3.times { loan.ensure_amortization_schedule_current! }

    assert_equal 360, loan.amortizations.count
  end

  test "ensure_amortization_schedule_current! serializes the check-then-rebuild through a row lock" do
    loan_account = Account.create! \
      family: families(:dylan_family),
      name: "Mortgage Loan",
      balance: 500000,
      currency: "USD",
      accountable: Loan.create!(
        subtype: "mortgage",
        interest_rate: 3.5,
        term_months: 360,
        rate_type: "fixed"
      )

    loan = loan_account.loan
    loan.expects(:with_lock).once.yields
    loan.ensure_amortization_schedule_current!
  end

  test "adds variable rate changes" do
    loan_account = Account.create! \
      family: families(:dylan_family),
      name: "Variable Rate Loan",
      balance: 500000,
      currency: "USD",
      accountable: Loan.create!(
        subtype: "line_of_credit",
        interest_rate: 3.5,
        term_months: 360,
        rate_type: "variable"
      )

    loan = loan_account.loan
    loan.add_variable_rate_change(Date.new(2027, 1, 1), 4.0)
    loan.add_variable_rate_change(Date.new(2028, 1, 1), 4.5)

    assert_equal 2, loan.variable_rates.length
    assert_equal 4.0, loan.variable_rates[0][1]
    assert_equal 4.5, loan.variable_rates[1][1]
    assert_equal Date.new(2027, 1, 1), loan.next_rate_change_date

    travel_to Date.new(2027, 1, 2) do
      assert_equal Date.new(2028, 1, 1), loan.next_rate_change_date
    end

    travel_to Date.new(2028, 1, 2) do
      assert_nil loan.next_rate_change_date
    end
  end

  test "gets current variable rate based on date" do
    loan_account = Account.create! \
      family: families(:dylan_family),
      name: "Variable Rate Loan",
      balance: 500000,
      currency: "USD",
      accountable: Loan.create!(
        subtype: "line_of_credit",
        interest_rate: 3.5,
        term_months: 360,
        rate_type: "variable",
        variable_rate_schedule: {
          "2024-01-01" => 3.5,
          "2026-01-01" => 4.0,
          "2027-01-01" => 4.5
        }
      )

    loan = loan_account.loan
    assert_equal 3.5, loan.current_variable_rate(Date.new(2024, 6, 1))
    assert_equal 4.0, loan.current_variable_rate(Date.new(2026, 6, 1))
    assert_equal 4.5, loan.current_variable_rate(Date.new(2027, 6, 1))
  end
end
