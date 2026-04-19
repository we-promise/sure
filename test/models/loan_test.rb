require "test_helper"

class LoanTest < ActiveSupport::TestCase
  test "rejects invalid subtype" do
    loan = Loan.new(subtype: "invalid")

    assert_not loan.valid?
    assert_includes loan.errors[:subtype], "is not included in the list"
  end

  def create_loan(attrs = {})
    Loan.create!({
      interest_rate: 3.5,
      term_months: 360,
      rate_type: "fixed",
      start_date: Date.new(2024, 1, 1)
    }.merge(attrs))
  end

  # =========================
  # monthly_payment
  # =========================

  test "calculates correct monthly payment for fixed rate loan" do
    loan_account = Account.create! \
      family: families(:dylan_family),
      name: "Mortgage Loan",
      balance: 500000,
      currency: "USD",
      accountable: create_loan

    assert_equal 2245, loan_account.loan.monthly_payment.amount
  end
  # =========================
  # months_elapsed
  # =========================
  test "months_elapsed calculates elapsed months correctly" do
    loan = Loan.new(
      interest_rate: 3.5,
      term_months: 12,
      rate_type: "fixed",
      start_date: Date.new(2024, 1, 15)
    )

    # before start
    assert_equal 0, loan.months_elapsed(as_of: Date.new(2023, 12, 1))

    # same month before the day
    assert_equal 0, loan.months_elapsed(as_of: Date.new(2024, 1, 10))

    # exactly one month later
    assert_equal 1, loan.months_elapsed(as_of: Date.new(2024, 2, 15))

    # month not fully reached
    assert_equal 0, loan.months_elapsed(as_of: Date.new(2024, 2, 10))

    # several months later
    assert_equal 3, loan.months_elapsed(as_of: Date.new(2024, 4, 15))

    # capped at term_months
    assert_equal 12, loan.months_elapsed(as_of: Date.new(2030, 1, 1))
  end
  # =========================
  # remaining_months
  # =========================
  test "remaining_months returns correct remaining duration" do
    loan = Loan.new(
      interest_rate: 3.5,
      term_months: 12,
      rate_type: "fixed",
      start_date: Date.new(2024, 1, 15)
    )

    # before loan start
    assert_equal 12, loan.remaining_months(as_of: Date.new(2023, 12, 1))

    # at start
    assert_equal 12, loan.remaining_months(as_of: Date.new(2024, 1, 15))

    # after one month
    assert_equal 11, loan.remaining_months(as_of: Date.new(2024, 2, 15))

    # after several months
    assert_equal 9, loan.remaining_months(as_of: Date.new(2024, 4, 15))

    # after loan term
    assert_equal 0, loan.remaining_months(as_of: Date.new(2030, 1, 1))
  end
  test "remaining_months returns nil when term_months is nil" do
    loan = Loan.new(
      interest_rate: 3.5,
      rate_type: "fixed",
      start_date: Date.new(2024, 1, 1)
    )

    assert_nil loan.remaining_months(as_of: Date.new(2024, 6, 1))
  end
  # =========================
  # finished?
  # =========================
  test "finished? returns true when loan term has been reached" do
    loan = Loan.new(
      interest_rate: 3.5,
      term_months: 12,
      rate_type: "fixed",
      start_date: Date.new(2024, 1, 15)
    )

    # before loan start
    refute loan.finished?(as_of: Date.new(2023, 12, 1))

    # during loan
    refute loan.finished?(as_of: Date.new(2024, 6, 15))

    # exactly at term
    assert loan.finished?(as_of: Date.new(2025, 1, 15))

    # after term
    assert loan.finished?(as_of: Date.new(2030, 1, 1))
  end
  test "finished? returns nil when term_months is nil" do
    loan = Loan.new(
      interest_rate: 3.5,
      rate_type: "fixed",
      start_date: Date.new(2024, 1, 1)
    )
    assert_nil loan.finished?(as_of: Date.new(2024, 6, 1))
  end
  # =========================
  # amortization_schedule
  # =========================
  test "amortization_schedule returns cached schedule for fixed rate loans" do
    loan = Loan.new(
      interest_rate: 3.5,
      term_months: 12,
      rate_type: "fixed",
      start_date: Date.today
    )

    expected_schedule = [ { month: 1 } ]

    loan.stub :cache_key_with_version, "loan/1" do
      loan.stub :generate_amortization_schedule, expected_schedule do
        Rails.cache.clear

        result = loan.amortization_schedule

        assert_equal expected_schedule, result
      end
    end
  end
  test "amortization_schedule returns empty array when loan is not eligible" do
    loan = Loan.new(
      interest_rate: nil,
      term_months: 12,
      rate_type: "fixed"
    )

    assert_equal [], loan.amortization_schedule
  end
  test "amortization_schedule returns empty array when rate_type is not fixed" do
    loan = Loan.new(
      interest_rate: 3.5,
      term_months: 12,
      rate_type: "variable"
    )

    assert_equal [], loan.amortization_schedule
  end
  # =========================
  # payment_date_for
  # =========================
  test "payment_date_for returns the correct payment date" do
    loan = Loan.new(start_date: Date.new(2024, 1, 15))

    assert_equal Date.new(2024, 1, 15), loan.payment_date_for(1)
    assert_equal Date.new(2024, 2, 15), loan.payment_date_for(2)
    assert_equal Date.new(2024, 3, 15), loan.payment_date_for(3)
  end
  test "payment_date_for returns nil when start_date is missing" do
    loan = Loan.new(start_date: nil)

    assert_nil loan.payment_date_for(1)
  end

  test "payment_date_for returns nil when month_number is invalid" do
    loan = Loan.new(start_date: Date.new(2024, 1, 1))

    assert_nil loan.payment_date_for(nil)
    assert_nil loan.payment_date_for(0)
    assert_nil loan.payment_date_for(-1)
  end
  test "payment_date_for handles end-of-month correctly" do
    loan = Loan.new(start_date: Date.new(2024, 1, 31))

    assert_equal Date.new(2024, 2, 29), loan.payment_date_for(2) # leap year
    assert_equal Date.new(2024, 3, 31), loan.payment_date_for(3)
  end

  # =========================
  # generate_amortization_schedule
  # =========================

  test "generate_amortization_schedule returns empty array when required fields are missing" do
    loan = Loan.new(
      interest_rate: 3.5,
      term_months: nil,
      insurance_rate: 0.3
    )

    assert_equal [], loan.generate_amortization_schedule
  end

  test "generate_amortization_schedule builds schedule with correct structure" do
    loan = Loan.new(
      interest_rate: 3.6,
      insurance_rate: 0.3,
      insurance_rate_type: "decreasing_life",
      term_months: 2,
      start_date: Date.new(2024, 1, 1)
    )

    loan.stub :original_balance, OpenStruct.new(amount: 100_000) do
      loan.stub :monthly_payment, OpenStruct.new(amount: 10_000) do
        schedule = loan.generate_amortization_schedule

        assert_equal 2, schedule.length

        row = schedule.first

        assert_equal 1, row[:month]
        assert_equal Date.new(2024, 1, 1), row[:date]
        assert row[:payment] > 0
        assert row[:interest] > 0
        assert row[:principal] > 0
        assert row[:insurance] > 0
        assert row[:remaining_balance] >= 0
      end
    end
  end

  test "generate_amortization_schedule decreases balance over time" do
    loan = Loan.new(
      interest_rate: 3.6,
      insurance_rate: 0.3,
      insurance_rate_type: "declining",
      term_months: 3,
      start_date: Date.new(2024, 1, 1)
    )

    loan.stub :original_balance, OpenStruct.new(amount: 100_000) do
      loan.stub :monthly_payment, OpenStruct.new(amount: 10_000) do
        schedule = loan.generate_amortization_schedule

        balances = schedule.map { |r| r[:remaining_balance] }

        assert balances[1] < balances[0]
        assert balances[2] < balances[1]
      end
    end
  end

  test "generate_amortization_schedule keeps insurance constant for level_term" do
    loan = Loan.new(
      interest_rate: 3.6,
      insurance_rate: 0.3,
      insurance_rate_type: "level_term",
      term_months: 3,
      start_date: Date.new(2024, 1, 1)
    )

    loan.stub :original_balance, OpenStruct.new(amount: 100_000) do
      loan.stub :monthly_payment, OpenStruct.new(amount: 10_000) do
        schedule = loan.generate_amortization_schedule

        insurances = schedule.map { |r| r[:insurance] }

        assert_equal insurances.first, insurances.second
        assert_equal insurances.first, insurances.third
      end
    end
  end
  # =========================
  # total_insurance
  # =========================

  test "total_insurance sums all insurance amounts from schedule" do
    loan = Loan.new

    schedule = [
      { insurance: 100 },
      { insurance: 200 },
      { insurance: 300 }
    ]

    loan.stub :amortization_schedule, schedule do
      loan.stub :account, OpenStruct.new(currency: "USD") do
        result = loan.total_insurance

        assert_equal 600, result.amount
        assert_equal "USD", result.currency.iso_code
      end
    end
  end

  test "total_insurance returns zero when schedule is empty" do
    loan = Loan.new

    loan.stub :amortization_schedule, [] do
      loan.stub :account, OpenStruct.new(currency: "USD") do
        result = loan.total_insurance

        assert_equal 0, result.amount
      end
    end
  end
  # =========================
  # total_paid
  # =========================

  test "total_paid returns monthly_payment multiplied by term_months" do
    loan = Loan.new(term_months: 12)

    loan.stub :monthly_payment, Money.new(1000, "USD") do
      result = loan.total_paid

      assert_equal 12000, result.amount
      assert_equal "USD", result.currency.iso_code
    end
  end

  test "total_paid returns nil when monthly_payment is nil" do
    loan = Loan.new(term_months: 12)

    loan.stub :monthly_payment, nil do
      assert_nil loan.total_paid
    end
  end

  test "total_paid returns nil when term_months is nil" do
    loan = Loan.new(term_months: nil)

    loan.stub :monthly_payment, Money.new(1000, "USD") do
      assert_nil loan.total_paid
    end
  end
  # =========================
  # total_interest
  # =========================

  test "total_interest returns total_paid minus original_balance" do
    loan = Loan.new

    loan.stub :total_paid, Money.new(12000, "USD") do
      loan.stub :original_balance, Money.new(10000, "USD") do
        result = loan.total_interest

        assert_equal 2000, result.amount
        assert_equal "USD", result.currency.iso_code
      end
    end
  end

  test "total_interest returns nil when total_paid is nil" do
    loan = Loan.new

    loan.stub :total_paid, nil do
      loan.stub :original_balance, Money.new(10000, "USD") do
        assert_nil loan.total_interest
      end
    end
  end

  test "total_interest returns nil when original_balance is nil" do
    loan = Loan.new

    loan.stub :total_paid, Money.new(12000, "USD") do
      loan.stub :original_balance, nil do
        assert_nil loan.total_interest
      end
    end
  end
  # =========================
  # remaining_balance_at
  # =========================

  test "remaining_balance_at returns remaining balance for the given month" do
    loan = Loan.new

    schedule = [
      { remaining_balance: 10_000.4 },
      { remaining_balance: 9_000.6 }
    ]

    loan.stub :amortization_schedule, schedule do
      loan.stub :account, OpenStruct.new(currency: "USD") do
        result = loan.remaining_balance_at(2)

        assert_equal 9001, result.amount
        assert_equal "USD", result.currency.iso_code
      end
    end
  end

  test "remaining_balance_at returns nil when month is outside schedule" do
    loan = Loan.new

    loan.stub :amortization_schedule, [] do
      loan.stub :account, OpenStruct.new(currency: "USD") do
        assert_nil loan.remaining_balance_at(1)
      end
    end
  end
  # =========================
  # payment_breakdown
  # =========================

  test "payment_breakdown returns breakdown for a given month" do
    loan = Loan.new(term_months: 12)

    schedule = [
      {
        date: Date.new(2025, 1, 1),
        principal: 8000,
        interest: 1000,
        insurance: 1000
      }
    ]

    loan.stub :amortization_schedule, schedule do
      loan.stub :account, OpenStruct.new(currency: "USD") do
        result = loan.payment_breakdown(month_number: 1)

        assert_equal 1, result[:month]
        assert_equal Date.new(2025, 1, 1), result[:date]

        assert_equal 8000, result[:principal].amount
        assert_equal 1000, result[:interest].amount
        assert_equal 1000, result[:insurance].amount
        assert_equal 10000, result[:total].amount

        assert_in_delta 0.8, result[:ratios][:principal], 0.001
        assert_in_delta 0.1, result[:ratios][:interest], 0.001
        assert_in_delta 0.1, result[:ratios][:insurance], 0.001
      end
    end
  end

  test "payment_breakdown uses months_elapsed when month_number is nil" do
    loan = Loan.new(term_months: 12)

    schedule = [
      { date: Date.new(2025, 1, 1), principal: 1000, interest: 500, insurance: 500 }
    ]

    loan.stub :months_elapsed, 1 do
      loan.stub :amortization_schedule, schedule do
        loan.stub :account, OpenStruct.new(currency: "USD") do
          result = loan.payment_breakdown

          assert_equal 1, result[:month]
        end
      end
    end
  end

  test "payment_breakdown clamps month_number to term_months" do
    loan = Loan.new(term_months: 1)

    schedule = [
      { date: Date.new(2025, 1, 1), principal: 1000, interest: 0, insurance: 0 }
    ]

    loan.stub :amortization_schedule, schedule do
      loan.stub :account, OpenStruct.new(currency: "USD") do
        result = loan.payment_breakdown(month_number: 10)

        assert_equal 1, result[:month]
      end
    end
  end

  test "payment_breakdown returns nil when schedule row is missing" do
    loan = Loan.new(term_months: 12)

    loan.stub :amortization_schedule, [] do
      assert_nil loan.payment_breakdown(month_number: 1)
    end
  end

  test "payment_breakdown returns zero ratios when total is zero" do
    loan = Loan.new(term_months: 12)

    schedule = [
      { date: Date.new(2025, 1, 1), principal: 0, interest: 0, insurance: 0 }
    ]

    loan.stub :amortization_schedule, schedule do
      loan.stub :account, OpenStruct.new(currency: "USD") do
        result = loan.payment_breakdown(month_number: 1)

        assert_equal 0.0, result[:ratios][:principal]
        assert_equal 0.0, result[:ratios][:interest]
        assert_equal 0.0, result[:ratios][:insurance]
      end
    end
  end
  # =========================
  # elapsed_ratio
  # =========================

  test "elapsed_ratio returns elapsed fraction of the term" do
    loan = Loan.new(term_months: 120)

    loan.stub :months_elapsed, 30 do
      result = loan.elapsed_ratio

      assert_in_delta 0.25, result, 0.0001
    end
  end

  test "elapsed_ratio is clamped to 1.0 when months_elapsed exceeds term" do
    loan = Loan.new(term_months: 120)

    loan.stub :months_elapsed, 200 do
      result = loan.elapsed_ratio

      assert_equal 1.0, result
    end
  end

  test "elapsed_ratio is clamped to 0.0 when months_elapsed is negative" do
    loan = Loan.new(term_months: 120)

    loan.stub :months_elapsed, -10 do
      result = loan.elapsed_ratio

      assert_equal 0.0, result
    end
  end

  test "elapsed_ratio returns nil when term_months is nil" do
    loan = Loan.new(term_months: nil)

    assert_nil loan.elapsed_ratio
  end

  test "elapsed_ratio returns nil when term_months is zero" do
    loan = Loan.new(term_months: 0)

    assert_nil loan.elapsed_ratio
  end
  # =========================
  # initial_leverage_ratio
  # =========================
  test "initial_leverage_ratio returns loan to down payment ratio" do
    loan = Loan.new(down_payment: 100_000)

    loan.stub :original_balance, Money.new(400_000, "USD") do
      result = loan.initial_leverage_ratio

      assert_in_delta 4.0, result, 0.0001
    end
  end

  test "initial_leverage_ratio returns nil when down_payment is nil" do
    loan = Loan.new(down_payment: nil)

    loan.stub :original_balance, Money.new(400_000, "USD") do
      assert_nil loan.initial_leverage_ratio
    end
  end

  test "initial_leverage_ratio returns nil when down_payment is zero" do
    loan = Loan.new(down_payment: 0)

    loan.stub :original_balance, Money.new(400_000, "USD") do
      assert_nil loan.initial_leverage_ratio
    end
  end
end
