require "test_helper"
require "csv"

# The fixture is SYNTHETIC. A real lender statement -- and anything derived
# from one, including balances, drawdown amounts and charge dates -- is
# personal financial data and must not enter this repository, even with names
# removed. See docs/loans/methodology.md for how the real reconciliation is to
# be run and what may be recorded from it.
#
# This file proves the fixture is well-formed, internally consistent, and free
# of identifying content. It is NOT yet the gate-G2 oracle: reconciling a real
# statement end-to-end is #11's remaining work, and the mid-cycle rate-change
# case cannot pass until the accrual/re-amortisation clocks are separated.
class Loan::ReconciliationTest < ActiveSupport::TestCase
  FIXTURE = Rails.root.join("test/fixtures/loan_reconciliation.csv")
  HEADERS = %w[date category amount balance annual_rate].freeze
  CATEGORIES = %w[loan_disbursal extra_repayment interest rate_change].freeze

  # Structural de-identification guard. Asserting an allowlist of shapes keeps
  # the check itself free of identifiers -- a denylist of names would have to
  # name them here, which is the leak it is trying to prevent.
  test "fixture holds only ISO dates, known categories and decimal amounts" do
    lines = File.read(FIXTURE).lines.map(&:chomp).reject(&:empty?)

    assert_equal HEADERS.join(","), lines.first

    lines.drop(1).each do |line|
      date, category, amount, balance, annual_rate = line.split(",")

      assert_match(/\A\d{4}-\d{2}-\d{2}\z/, date, "unexpected date token in #{line}")
      assert_includes CATEGORIES, category, "unexpected category in #{line}"
      [ amount, balance, annual_rate ].each do |value|
        assert_match(/\A-?\d+\.\d{2}\z/, value, "unexpected numeric token in #{line}")
      end
    end
  end

  test "fixture covers drawdown, interest, a rate change and extra repayments" do
    assert_equal 1, rows.count { |row| row["category"] == "loan_disbursal" }
    assert_equal 3, rows.count { |row| row["category"] == "interest" }
    assert_equal 1, rows.count { |row| row["category"] == "rate_change" }
    assert_equal 4, rows.count { |row| row["category"] == "extra_repayment" }

    assert_operator rows.index { |row| row["category"] == "rate_change" },
      :>, rows.index { |row| row["category"] == "interest" },
      "the rate change must fall after a charge so it lands mid-cycle"
  end

  # The previous fixture drifted from its own running balance in three places
  # and nothing detected it, because the suite only counted categories. A
  # statement whose movements do not sum to its balances cannot reconcile
  # against anything.
  test "every movement reconciles to the stated running balance" do
    previous = nil

    rows.each_with_index do |row, index|
      balance = decimal(row["balance"])

      if previous.nil?
        previous = balance
        next
      end

      expected = row["category"] == "rate_change" ? previous : previous + decimal(row["amount"])
      assert_equal expected, balance,
        "row #{index + 1} (#{row['date']} #{row['category']}) breaks the running balance"

      previous = balance
    end
  end

  # The previous fixture moved 3.43% -> 3.93% on a row categorised as an extra
  # repayment, so it described two rate changes while asserting one.
  test "every rate movement is declared by a rate_change row" do
    previous = nil

    rows.each_with_index do |row, index|
      rate = decimal(row["annual_rate"])

      unless previous.nil? || rate == previous
        assert_equal "rate_change", row["category"],
          "row #{index + 1} (#{row['date']}) moves the rate without declaring it"
      end

      previous = rate
    end
  end

  # #11 acceptance criterion: "Independent reference calculation agrees for
  # fixed / no-offset". The reference is written from the actual/365 formula
  # rather than from the simulator, then compared to the engine -- an
  # independent calculation that is never compared proves nothing.
  test "independent actual/365 reference agrees with Loan::InterestAccrual" do
    from_date = Date.new(2024, 1, 5)
    to_date = Date.new(2024, 2, 5)
    balance = BigDecimal("400000")
    annual_rate = BigDecimal("5")

    reference = (to_date - from_date).to_i * balance * annual_rate / 100 / 365

    assert_equal reference.round(20),
      Loan::InterestAccrual.calculate(
        from_date: from_date, to_date: to_date,
        balance: balance, annual_rate: annual_rate
      ).round(20)

    assert_equal reference.round(2),
      Loan::InterestAccrual.charge(
        currency_precision: 2,
        from_date: from_date, to_date: to_date,
        balance: balance, annual_rate: annual_rate
      )
  end

  # #11 acceptance criterion: the fixture is fed to the engine, not merely
  # validated for shape.
  #
  # Every interest row is reconciled by walking the fixture's own movements into
  # a change-point list and charging `Loan::InterestAccrual` over the window
  # since the previous charge. Expected values come from the fixture, and the
  # windows and segments come from the fixture -- nothing here is hardcoded from
  # the engine, so this fails if the engine's segmentation, day count, event
  # inclusivity or charge-point rounding changes.
  #
  # The second charge covers an extra repayment AND a mid-cycle rate change in
  # one window, so it exercises C6, C7, C10 and C13 together.
  test "every interest charge in the fixture reconciles through Loan::InterestAccrual" do
    charges = interest_charges

    assert_equal 3, charges.length, "the fixture must retain three charge windows"

    charges.each do |charge|
      actual = Loan::InterestAccrual.charge(
        currency_precision: 2,
        from_date: charge[:from_date],
        to_date: charge[:to_date],
        balance: charge[:opening_balance],
        annual_rate: charge[:opening_rate],
        change_points: charge[:change_points]
      )

      assert_equal charge[:expected], actual,
        "charge on #{charge[:to_date]} over #{charge[:from_date]}..#{charge[:to_date]} " \
        "(#{charge[:change_points].length} intra-window change point(s))"
    end
  end

  test "the mid-cycle rate change is segmented, not applied across the whole window" do
    charge = interest_charges.find { |c| c[:change_points].any? { |point| point.key?(:rate) } }

    assert_not_nil charge, "the fixture must contain a charge window with a mid-cycle rate change"

    flat_at_new_rate = Loan::InterestAccrual.charge(
      currency_precision: 2,
      from_date: charge[:from_date], to_date: charge[:to_date],
      balance: charge[:opening_balance],
      annual_rate: charge[:change_points].reverse.find { |point| point[:rate] }.fetch(:rate)
    )

    assert_not_equal flat_at_new_rate, charge[:expected],
      "if the whole window at the new rate matched the statement, the fixture could not " \
      "distinguish a segmented accrual from a retroactive one (C7)"
  end

  private

    # Walk the fixture into one charge window per `interest` row: the opening
    # balance and rate carried from the previous charge, and every movement in
    # between as a change point.
    def interest_charges
      charges = []
      window_start = nil
      opening_balance = nil
      opening_rate = nil
      running_balance = nil
      change_points = []

      rows.each do |row|
        date = Date.iso8601(row.fetch("date"))
        row_rate = decimal(row.fetch("annual_rate"))

        case row.fetch("category")
        when "loan_disbursal"
          window_start = date
          opening_balance = decimal(row.fetch("balance")).abs
          running_balance = opening_balance
          opening_rate = row_rate
        when "extra_repayment"
          # The window's OPENING balance must not move -- only the running
          # balance does, and it does so from this row's own date.
          running_balance -= decimal(row.fetch("amount"))
          change_points << { date: date, balance: running_balance }
        when "rate_change"
          change_points << { date: date, rate: row_rate }
        when "interest"
          charges << {
            from_date: window_start,
            to_date: date,
            opening_balance: opening_balance,
            opening_rate: opening_rate,
            change_points: change_points,
            expected: decimal(row.fetch("amount")).abs
          }
          # Interest is capitalised, so the next window opens on the stated
          # closing balance rather than on the pre-charge balance.
          window_start = date
          opening_balance = decimal(row.fetch("balance")).abs
          running_balance = opening_balance
          opening_rate = row_rate
          change_points = []
        end
      end

      charges
    end

    def rows
      @rows ||= CSV.parse(File.read(FIXTURE), headers: true).map(&:to_h)
    end

    def decimal(value)
      BigDecimal(value.to_s)
    end
end
