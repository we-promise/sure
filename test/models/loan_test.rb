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

  test "payoff_projection returns a memoized PayoffProjection for the loan" do
    loan_account = Account.create! \
      family: families(:dylan_family),
      name: "Mortgage Loan",
      balance: 500000,
      currency: "USD",
      accountable: Loan.create!(
        subtype: "mortgage",
        interest_rate: 3.5,
        term_months: 360,
        rate_type: "fixed",
        start_date: Date.current
      )

    loan = loan_account.loan
    assert_instance_of Loan::PayoffProjection, loan.payoff_projection
    assert_same loan.payoff_projection, loan.payoff_projection
  end

  test "payoff_chart_payload is nil when the current balance matches the original schedule" do
    loan = build_chart_loan(balance: 500000)

    assert_nil loan.payoff_chart_payload
  end

  # Was "payoff_chart_payload is nil for a variable rate loan". That assertion
  # predates #12: PayoffProjection#applicable? required fixed_rate?, so variable
  # loans got no projection and therefore no chart. #35 removed that gate --
  # giving variable loans a projection is the entire point of #12 -- so the
  # chart must now render for them too.
  test "payoff_chart_payload is produced for a variable rate loan" do
    loan = build_chart_loan(balance: 500000, rate_type: "variable")
    loan.account.update!(balance: 450000)

    payload = loan.payoff_chart_payload

    assert_not_nil payload, "variable-rate loans get a projection since #12, so they get a chart"
    assert payload[:original_projection].any?
    assert payload[:accelerated_projection].any?
    assert_equal "USD", payload[:currency]
  end

  test "payoff_chart_payload includes both forward series and a green accent when ahead of schedule" do
    loan = build_chart_loan(balance: 500000)
    loan.account.update!(balance: 450000) # extra $50k paid toward principal

    payload = loan.payoff_chart_payload

    assert payload.present?
    assert_equal true, payload[:ahead]
    assert_equal "USD", payload[:currency]
    assert_equal Date.current.iso8601, payload[:today]
    assert_equal 450000.0, payload[:current_balance][:balance]
    assert payload[:original_projection].length > payload[:accelerated_projection].length
    assert payload[:original_payoff_date].present?
    assert payload[:accelerated_payoff_date].present?
    assert payload[:accelerated_payoff_date] < payload[:original_payoff_date]
  end

  test "payoff_chart_payload reflects a behind-schedule balance with ahead false" do
    loan = build_chart_loan(balance: 500000)
    loan.account.update!(balance: 550000) # owes more than originally contracted

    payload = loan.payoff_chart_payload

    assert payload.present?
    assert_equal false, payload[:ahead]
  end

  # Regression: the solid line's data used to be keyed "history", which
  # implies real historical balances. It's actually the original schedule's
  # theoretical/contracted trajectory (this app doesn't track daily balance
  # history) -- keyed and labeled accordingly so the chart can't be
  # misread as showing real past balances.
  test "payoff_chart_payload labels the scheduled trajectory explicitly rather than as history" do
    loan = build_chart_loan(balance: 500000)
    loan.account.update!(balance: 450000)

    payload = loan.payoff_chart_payload

    assert_not payload.key?(:history)
    assert payload.key?(:scheduled_history)
    assert_equal "Scheduled (contracted terms)", payload[:labels][:scheduled]
  end

  test "payoff_chart_payload includes an accessible label and description with the key figures" do
    loan = build_chart_loan(balance: 500000)
    loan.account.update!(balance: 450000)

    payload = loan.payoff_chart_payload

    assert_equal "Loan payoff comparison chart", payload[:aria_label]
    assert_includes payload[:aria_description], loan.payoff_projection.current_balance.to_s
    assert_includes payload[:aria_description], I18n.l(loan.amortization_schedule.payoff_date, format: :long)
    assert_includes payload[:aria_description], I18n.l(loan.payoff_projection.payoff_date, format: :long)
  end

  # Regression: chart dates used to inherit PayoffProjection's payment-date
  # anchoring bug (Date.current.next_month instead of the loan's real
  # payment anchor day). Verifies the chart's forward-looking series line up
  # with the persisted schedule's actual next payment date for a loan whose
  # anchor day differs from today's.
  test "payoff_chart_payload's projection series start on the loan's actual next scheduled payment date" do
    start_date = 2.years.ago.to_date.change(day: 15)
    loan = build_chart_loan(balance: 500000, start_date: start_date)
    loan.ensure_amortization_schedule_current!
    loan.account.update!(balance: 450000)

    next_scheduled_date = loan.amortizations.where("payment_date > ?", Date.current).ordered.first.payment_date
    assert_not_equal Date.current.next_month, next_scheduled_date, "test setup should exercise a real anchor mismatch"

    payload = loan.payoff_chart_payload

    assert_equal next_scheduled_date.iso8601, payload[:accelerated_projection].first[:date]
    assert_equal next_scheduled_date.iso8601, payload[:original_projection].first[:date]
  end

  test "payoff_projection_with_extra returns a fresh projection boosted by the given amount" do
    loan = build_chart_loan(balance: 500000)

    with_extra = loan.payoff_projection_with_extra(amount: "100", frequency: "monthly")

    assert_not_same loan.payoff_projection, with_extra
    assert_equal loan.payoff_projection.monthly_payment + Money.new(100, "USD"), with_extra.monthly_payment
  end

  test "payoff_chart_payload accepts a caller-supplied projection and labels it from the raw what-if input" do
    loan = build_chart_loan(balance: 500000)
    with_extra = loan.payoff_projection_with_extra(amount: "200", frequency: "monthly")

    payload = loan.payoff_chart_payload(
      projection: with_extra,
      extra_payment_amount: "200",
      extra_payment_frequency: "monthly"
    )

    assert payload.present?
    assert_equal true, payload[:ahead]
    assert_equal "Modeling an extra $200.00 per month", payload[:extra_payment_label]

    baseline_payload = loan.payoff_chart_payload
    assert_nil baseline_payload # baseline (no extra) still doesn't diverge for an untouched balance
  end

  # Regression: aria_description used to read straight from
  # `payoff_projection`/`amortization_schedule` instead of the passed-in
  # `projection`, so a what-if request's screen-reader description silently
  # kept describing the baseline (no-extra) figures while the visible chart
  # and summary cards showed the boosted ones -- sighted and screen-reader
  # users would see contradictory numbers for the same chart.
  test "payoff_chart_payload's aria_description reflects the caller-supplied projection, not the baseline" do
    loan = build_chart_loan(balance: 500000)
    baseline_payoff_date = loan.payoff_projection.payoff_date
    with_extra = loan.payoff_projection_with_extra(amount: "200", frequency: "monthly")
    assert_not_equal baseline_payoff_date, with_extra.payoff_date, "test setup should exercise a real divergence"

    payload = loan.payoff_chart_payload(projection: with_extra, extra_payment_amount: "200", extra_payment_frequency: "monthly")

    assert_includes payload[:aria_description], I18n.l(with_extra.payoff_date, format: :long)
    assert_not_includes payload[:aria_description], I18n.l(baseline_payoff_date, format: :long)
  end

  test "payoff_chart_payload defaults to the memoized baseline projection when none is given" do
    loan = build_chart_loan(balance: 500000)
    loan.account.update!(balance: 450000)

    assert_equal loan.payoff_projection.payoff_date, loan.payoff_chart_payload[:accelerated_payoff_date]&.then { Date.iso8601(_1) }
  end

  test "payoff_chart_payload is unaffected by what-if params when the extra payment doesn't cover interest" do
    loan = build_chart_loan(balance: 500000)
    loan.account.update!(balance: 800000) # payment (even boosted a little) still can't cover interest
    with_extra = loan.payoff_projection_with_extra(amount: "10", frequency: "monthly")

    payload = loan.payoff_chart_payload(projection: with_extra)

    assert_nil payload
  end

  private
    def build_chart_loan(balance:, interest_rate: 3.5, term_months: 360, start_date: Date.current, rate_type: "fixed")
      account = Account.create! \
        family: families(:dylan_family),
        name: "Chart Loan #{SecureRandom.hex(4)}",
        balance: balance,
        currency: "USD",
        accountable: Loan.create!(
          subtype: "mortgage",
          interest_rate: interest_rate,
          term_months: term_months,
          rate_type: rate_type,
          start_date: start_date
        )

      account.entries.create!(
        name: "Starting balance",
        amount: balance,
        currency: "USD",
        date: start_date,
        entryable: Valuation.new(kind: "opening_anchor")
      )

      # Amortization rebuilds happen asynchronously (after_save enqueues
      # LoanAmortizationRebuildJob rather than rebuilding inline), and
      # payoff_chart_payload's projection requires Loan#schedule_current? --
      # build the persisted schedule synchronously here so tests don't need
      # to perform_enqueued_jobs just to exercise the chart payload.
      account.loan.tap(&:rebuild_amortization_schedule)
    end
end
