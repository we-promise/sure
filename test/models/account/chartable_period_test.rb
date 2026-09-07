require "test_helper"

# D5 / FR-501 (#17). "All" on a loan chart must mean the loan's own history.
class Account::ChartablePeriodTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @all_time = Period.from_key("all_time")
  end

  test "a loan's all-time chart starts at the loan's own earliest date" do
    loan = seasoned_account(Loan.new(rate_type: "fixed", interest_rate: 5, term_months: 360))

    period = loan.chart_period(@all_time)

    assert_equal Balance::BaseCalculator.new(loan).calculation_start_date, period.start_date,
      "the loan chart must start where the loan's own balances start"
    assert_not_equal @all_time.start_date, period.start_date,
      "the fixture must differ from the family-scoped start, or this proves nothing"
    assert_equal Date.current, period.end_date
  end

  # The acceptance criteria ask for this to be asserted, not inspected: the
  # branch changes a shared code path, and "I only meant it for loans" is not
  # evidence. Every other accountable type must come back byte-identical.
  test "no other account type is affected" do
    [ Depository.new, Investment.new, Property.new, Vehicle.new, CreditCard.new ].each do |accountable|
      account = seasoned_account(accountable)

      period = account.chart_period(@all_time)

      assert_equal @all_time.start_date, period.start_date,
        "#{accountable.class.name} must keep the family-scoped all-time start"
      assert_equal @all_time.end_date, period.end_date,
        "#{accountable.class.name} must keep the family-scoped all-time end"
    end
  end

  test "every other period on a loan is left alone" do
    loan = seasoned_account(Loan.new(rate_type: "fixed", interest_rate: 5, term_months: 360))

    %w[last_30_days last_90_days last_365_days current_year last_5_years].each do |key|
      requested = Period.from_key(key)

      assert_equal requested.start_date, loan.chart_period(requested).start_date,
        "#{key} must not be rewritten by the all-time branch"
    end
  end

  # Period::PERIODS is what net worth, reports and the dashboard read. The
  # substitution happens per account and must not reach it.
  test "the shared all-time period definition is untouched" do
    loan = seasoned_account(Loan.new(rate_type: "fixed", interest_rate: 5, term_months: 360))
    loan.chart_period(@all_time)

    assert_equal @all_time.start_date, Period.from_key("all_time").start_date,
      "Period::PERIODS must be unchanged after a loan resolves its own chart period"
  end

  test "a loan with no history falls back rather than charting from today" do
    loan = @family.accounts.create!(
      name: "Brand New Loan", balance: 1000, currency: "USD",
      accountable: Loan.new(rate_type: "fixed", interest_rate: 5, term_months: 360)
    )

    period = loan.chart_period(@all_time)

    assert_equal @all_time.start_date, period.start_date,
      "a zero-width period would render an empty chart; fall back instead"
  end

  private

    # An account whose own earliest date is well before the family-scoped
    # all-time start, so the substitution is observable.
    def seasoned_account(accountable)
      account = @family.accounts.create!(
        name: "Seasoned #{accountable.class.name} #{SecureRandom.hex(3)}",
        balance: 250_000,
        currency: "USD",
        accountable: accountable
      )
      account.entries.create!(
        date: 8.years.ago.to_date, amount: 250_000, currency: "USD",
        name: "Opening", entryable: Valuation.new(kind: "opening_anchor")
      )
      account
    end
end
