require "test_helper"

# D5 / FR-501 (#17). "All" on a loan chart must mean the loan's own history.
class Account::ChartablePeriodTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    # Without a session, `Period.from_key("all_time")` reads `Current.family` as
    # nil and silently uses its 5-years-ago fallback -- so every assertion below
    # would compare against that fallback while claiming to compare against the
    # family-scoped start. The test would still pass, for the wrong reason
    # (cubic, #81). `Current.family` delegates through the session's user, so it
    # is established that way rather than assigned.
    Current.session = Session.create!(user: users(:family_admin))
    assert_equal @family, Current.family, "the family context must be real, not assumed"

    @all_time = Period.from_key("all_time")
    assert_equal @family.oldest_entry_date, @all_time.start_date,
      "all_time must be genuinely family-scoped here, not the 5-year fallback"
  end

  teardown do
    Current.session = nil
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

    # Read AFTER the fixture exists. The seasoned account backdates an entry,
    # which legitimately moves the family's oldest entry date -- comparing
    # against the value captured in setup would fail for that reason and say
    # nothing about whether PERIODS was mutated.
    before = Period.from_key("all_time").start_date
    loan.chart_period(Period.from_key("all_time"))

    assert_equal before, Period.from_key("all_time").start_date,
      "Period::PERIODS must be unchanged after a loan resolves its own chart period"
  end

  # A loan originated TODAY has history -- one day of it. Falling back here
  # would chart years of flat zero before it existed, which is the defect this
  # branch removes (cubic, #81).
  test "a loan originated today still scopes to itself" do
    loan = @family.accounts.create!(
      name: "Originated Today", balance: 250_000, currency: "USD",
      accountable: Loan.new(rate_type: "fixed", interest_rate: 5, term_months: 360)
    )

    period = loan.chart_period(Period.from_key("all_time"))

    assert_equal Date.current, period.start_date,
      "an origination today is history, not missing history"
  end

  # UI::PeriodPicker selects on `period.key`. A keyless custom period left the
  # picker with nothing selected and the chart labelled "30D" while showing
  # all-time data (cubic, #81).
  test "the substituted period keeps the all_time key so the picker still selects it" do
    loan = seasoned_account(Loan.new(rate_type: "fixed", interest_rate: 5, term_months: 360))

    period = loan.chart_period(Period.from_key("all_time"))

    assert_equal "all_time", period.key
    assert_equal "all_time", UI::PeriodPicker.new(selected: period, url: "/x").selected_key
  end

  # The genuine "no history" case is a nil calculation start date. It cannot be
  # built by creating an account -- a persisted account always carries an
  # opening anchor dated today, which IS history, and the originated-today test
  # above covers that. Stubbed so the branch is exercised rather than assumed.
  test "a loan with no calculable start date falls back" do
    loan = seasoned_account(Loan.new(rate_type: "fixed", interest_rate: 5, term_months: 360))
    Balance::BaseCalculator.any_instance.stubs(:calculation_start_date).returns(nil)

    requested = Period.from_key("all_time")

    assert_equal requested.start_date, loan.chart_period(requested).start_date,
      "with nothing to scope to, the requested period stands"
  end

  test "a loan whose start date is in the future falls back" do
    loan = seasoned_account(Loan.new(rate_type: "fixed", interest_rate: 5, term_months: 360))
    Balance::BaseCalculator.any_instance.stubs(:calculation_start_date).returns(Date.current + 1.year)

    requested = Period.from_key("all_time")

    assert_equal requested.start_date, loan.chart_period(requested).start_date,
      "a chart cannot start after it ends"
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
