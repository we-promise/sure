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

  private

    def rows
      @rows ||= CSV.parse(File.read(FIXTURE), headers: true).map(&:to_h)
    end

    def decimal(value)
      BigDecimal(value.to_s)
    end
end
