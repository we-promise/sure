require "test_helper"
require "digest"

# The default convention must charge exactly what the engine charged before
# day-count conventions existed, on every path that reaches Loan::Simulator.
#
# Each expected figure below was captured from we-promise/sure `main` at
# 20352e1a0, whose engine has no day-count convention, by running this file
# with BASELINE_CAPTURE=1. They are not read back out of the patched engine, so
# a default that moved by a cent on any row fails here.
#
# A digest covers every row of a scenario; the spot figures beside it say which
# part moved when the digest fails.
class Loan::DefaultConventionBaselineTest < ActiveSupport::TestCase
  AS_OF = Date.new(2027, 1, 15)
  START = Date.new(2026, 1, 1)

  EXPECTED = {
    "fixed_360" => "579580c8f4df4a01fd6b316d80bdfe097e966afb0d7796d244392679d6e901d2",
    "straddle_reamortize" => "9e61e14f16ee016da4b4089d01af1c9e4db4108f8fdb115612f1eb2f0bc1a58e",
    "on_payment_date" => "f035430d4e3eaec3053a37325c80bb55b171cf8dbfd58f20700b1d8e58b2fadd",
    "hold" => "12397dbaaa26b929587379965730b592947f394c8e1b1339bc3f8f3127d893e7",
    "loan_schedule" => "5026346a0b7ad4b3b832a09db1566efcc109d776cc6b5b270121245c06887eb1",
    "projection_on_contract" => "8e3a7b3abc0155a01546489433d0390d895eb1f29b69094a4b2b2709468fe218",
    "projection_ahead" => "dee43f46f7da315bfc9a8f2d7bfb9200e20122337930f6fd7259dff9534651e7",
    "projection_behind" => "407c0810c113d44f61fc0a9c1e0dda76f2e330c1f97609ebfcaae34f549f931c",
    "totals" => "dea5348c982598b060dd2951f650251b38ffa6498308f1a8ccdbae6f527c558b"
  }.freeze

  setup do
    @family = families(:dylan_family)
  end

  test "a fixed-rate loan charges what it charged before, over its whole term" do
    check "fixed_360", simulate(rate_for: ->(_date) { 6 }, periods: 360)
  end

  test "a rate change inside a period sizes and charges what it did before" do
    check "straddle_reamortize", simulate(rate_for: ->(date) { date < Date.new(2026, 6, 15) ? 6 : 8 }, periods: 120)
  end

  test "a rate change on a payment date sizes and charges what it did before" do
    check "on_payment_date", simulate(rate_for: ->(date) { date < Date.new(2026, 6, 1) ? 6 : 8 }, periods: 120)
  end

  test "a held payment through a rate change charges what it did before" do
    check "hold", simulate(rate_for: ->(date) { date < Date.new(2026, 6, 15) ? 6 : 8 }, periods: 120, payment_strategy: :hold)
  end

  test "a stored loan's schedule is what it was before" do
    loan = build_loan(variable_rate_schedule: { "2026-06-15" => "8.0" })

    check "loan_schedule", loan.amortization_schedule.payments.map { |payment| canonical_payment(payment) }
  end

  test "a projection on contract, ahead of it and behind it is what it was before" do
    { "on_contract" => 0, "ahead" => -25_000, "behind" => 5_000 }.each do |position, offset|
      loan = build_loan
      scheduled = loan.amortization_schedule.payments.select { |p| p.date <= AS_OF }.last.ending_balance.amount
      loan.account.update!(balance: scheduled + offset)

      projection = loan.payoff_projection(as_of: AS_OF)
      check "projection_#{position}", [
        projection.payments.map { |row| canonical_row(row) },
        projection.payoff_date&.iso8601,
        projection.total_interest.to_s,
        projection.converged?,
        projection.balloon_amount.to_s
      ]
    end
  end

  test "a loan's total cost and decreasing-life insurance are what they were before" do
    loan = build_loan(insurance_rate: 1.2, insurance_rate_type: "decreasing_life")

    check "totals", [ loan.total_cost.to_s, loan.total_insurance.to_s ]
  end

  private
    def simulate(rate_for:, periods:, payment_strategy: :reamortize)
      Loan::Simulator.new(
        starting_balance: 300_000,
        accrual_start_date: START,
        payment_schedule: (1..periods).map { |n| START >> n },
        accrual_rate_for: rate_for,
        currency_precision: 2,
        payment_strategy: payment_strategy
      ).run.then { |result| [ result.payments.map { |row| canonical_row(row) }, result.converged?, result.balloon_amount.to_s ] }
    end

    def build_loan(variable_rate_schedule: {}, insurance_rate: nil, insurance_rate_type: nil)
      account = Account.create!(
        family: @family, name: "Baseline #{SecureRandom.hex(4)}", balance: 300_000, currency: "USD",
        accountable: Loan.new(subtype: "mortgage", interest_rate: 6, term_months: 360,
                              rate_type: variable_rate_schedule.empty? ? "fixed" : "variable",
                              start_date: START, variable_rate_schedule: variable_rate_schedule,
                              insurance_rate: insurance_rate, insurance_rate_type: insurance_rate_type)
      )
      account.entries.create!(date: START, name: "Opening balance", amount: 300_000, currency: "USD",
                              entryable: Valuation.new(kind: "opening_anchor"))
      account.loan
    end

    # Every key, in a fixed order, with BigDecimals in plain notation, so the
    # digest cannot depend on hash ordering or on how a number prints.
    def canonical_row(row)
      row.sort_by { |key, _| key.to_s }.map { |key, value| "#{key}=#{scalar(value)}" }.join(";")
    end

    def canonical_payment(payment)
      payment.to_h.sort_by { |key, _| key.to_s }.map { |key, value| "#{key}=#{scalar(value)}" }.join(";")
    end

    def scalar(value)
      case value
      when BigDecimal then value.to_s("F")
      when Money then "#{value.amount.to_s("F")} #{value.currency.iso_code}"
      when Date then value.iso8601
      else value.to_s
      end
    end

    def check(name, figures)
      digest = Digest::SHA256.hexdigest(figures.inspect)

      if ENV["BASELINE_CAPTURE"]
        puts "BASELINE #{name.inspect} => #{digest.inspect},"
        return
      end

      assert EXPECTED.key?(name), "no baseline captured for #{name}"
      assert_equal EXPECTED.fetch(name), digest, "#{name} no longer matches the engine before day-count conventions"
    end
end
