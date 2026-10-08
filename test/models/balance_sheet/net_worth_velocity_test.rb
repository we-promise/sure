require "test_helper"

class BalanceSheet::NetWorthVelocityTest < ActiveSupport::TestCase
  include BalanceTestHelper

  DAYS_PER_MONTH = BigDecimal("365.2425") / 12

  setup do
    @family = families(:empty)
    @today = Date.current
    # 30 days ending today, and the 30 days before it.
    @period = Period.custom(start_date: @today - 29, end_date: @today)
    @prior = Period.custom(start_date: @today - 59, end_date: @today - 30)
    @account = @family.accounts.create!(name: "Savings", currency: "USD", balance: 0, accountable: Depository.new)
  end

  test "a flat series has zero velocity" do
    track(history_from: @prior.start_date) { 10_000 }

    assert_equal 0, velocity.velocity.amount
  end

  test "velocity is the change over the period, per month" do
    track(history_from: @prior.start_date) { |date| date <= @period.start_date ? 10_000 : 10_000 + (date - @period.start_date).to_i * 100 }

    # 29 days from the first point to the last, 100 a day.
    assert_in_delta 2_900 / 29.0 * DAYS_PER_MONTH, velocity.velocity.amount, 0.01
  end

  test "a falling series has negative velocity" do
    track(history_from: @prior.start_date) { |date| 20_000 - [ (date - @period.start_date).to_i, 0 ].max * 50 }

    assert_operator velocity.velocity.amount, :<, 0
  end

  test "momentum is positive when growth speeds up" do
    track(history_from: @prior.start_date) { |date| level(date, prior_gain: 1_000, current_gain: 3_000) }

    assert_operator velocity.momentum.amount, :>, 0
  end

  test "momentum flips sign when growth slows" do
    track(history_from: @prior.start_date) { |date| level(date, prior_gain: 3_000, current_gain: 1_000) }

    assert_operator velocity.velocity.amount, :>, 0, "net worth is still growing"
    assert_operator velocity.momentum.amount, :<, 0, "but more slowly than before"
  end

  test "momentum is zero when the pace holds" do
    track(history_from: @prior.start_date) { |date| level(date, prior_gain: 2_000, current_gain: 2_000) }

    assert_in_delta 0, velocity.momentum.amount, 0.5
  end

  test "momentum is the difference between this period's velocity and the prior period's" do
    track(history_from: @prior.start_date) { |date| level(date, prior_gain: 1_000, current_gain: 3_000) }

    expected = (BigDecimal(2_000) / 29) * DAYS_PER_MONTH
    assert_in_delta expected, velocity.momentum.amount, 0.5
  end

  test "the prior period is the same length, ending the day before this one starts" do
    prior = velocity.prior_period

    assert_equal @prior.start_date, prior.start_date
    assert_equal @prior.end_date, prior.end_date
    assert_equal @period.days, prior.days
  end

  test "there is no velocity when the family has no history" do
    assert_nil velocity.velocity
    assert_nil velocity.momentum
  end

  # Before the first entry the net worth series reads zero, so a prior window that
  # starts earlier than the data would look like a flat period and momentum would
  # simply equal velocity. It is withheld instead.
  test "momentum is withheld when history starts inside the prior period" do
    track(history_from: @prior.start_date + 5) { |date| level(date, prior_gain: 1_000, current_gain: 3_000) }

    assert_not_nil velocity.velocity
    assert_nil velocity.momentum
  end

  test "momentum is available when history starts exactly where the prior period does" do
    track(history_from: @prior.start_date) { |date| level(date, prior_gain: 1_000, current_gain: 3_000) }

    assert_not_nil velocity.momentum
  end

  # An account added mid-period moves net worth from nothing to its balance. That
  # is not growth, so neither figure is offered until a full period is covered.
  test "velocity is withheld when history starts inside the period" do
    track(history_from: @period.start_date + 3) { |date| level(date, prior_gain: 0, current_gain: 3_000) }

    assert_nil velocity.velocity
    assert_nil velocity.momentum
  end

  # One account with a long history must not vouch for another that opens inside
  # the window: its balance arrives from nothing, and the series counts that as
  # growth.
  test "velocity is withheld when any account's history starts inside the period" do
    track(history_from: @prior.start_date) { |date| level(date, prior_gain: 1_000, current_gain: 3_000) }
    newcomer = @family.accounts.create!(name: "New", currency: "USD", balance: 0, accountable: Depository.new)
    newcomer.entries.create!(
      name: "Opening", date: @period.start_date + 3, amount: 5_000, currency: "USD",
      entryable: Valuation.new(kind: "opening_anchor")
    )

    assert_nil velocity.velocity
    assert_nil velocity.momentum
  end

  test "an account with no entries does not hold the figures back" do
    track(history_from: @prior.start_date) { |date| level(date, prior_gain: 1_000, current_gain: 3_000) }
    @family.accounts.create!(name: "Empty", currency: "USD", balance: 0, accountable: Depository.new)

    assert_not_nil velocity.velocity
    assert_not_nil velocity.momentum
  end

  # The series is not drawn from a pending transaction, so one dated before the
  # real history must not stand in for it.
  test "a pending transaction dated before the history does not count as history" do
    track(history_from: @period.start_date + 3) { |date| level(date, prior_gain: 0, current_gain: 3_000) }
    @account.entries.create!(
      name: "Pending", date: @prior.start_date - 5, amount: 10, currency: "USD",
      entryable: Transaction.new(extra: { "simplefin" => { "pending" => true } })
    )

    assert_nil velocity.velocity
  end

  # The issue names NetWorthBreakdownSeriesBuilder#breakdown_series as the source,
  # which also keeps the figure on the series the Reports page draws.
  test "velocity and momentum are read from the breakdown series, one window each" do
    track(history_from: @prior.start_date) { 10_000 }
    points = ->(from, to) { [ { date: @period.start_date, value: Money.new(from, "USD") }, { date: @period.end_date, value: Money.new(to, "USD") } ] }
    current_window = { values: points.call(10_000, 12_900) }
    prior_window = { values: [ { date: @prior.start_date, value: Money.new(10_000, "USD") }, { date: @prior.end_date, value: Money.new(10_580, "USD") } ] }
    BalanceSheet::NetWorthBreakdownSeriesBuilder.any_instance.expects(:breakdown_series)
      .with(period: @period).returns(current_window)
    BalanceSheet::NetWorthBreakdownSeriesBuilder.any_instance.expects(:breakdown_series)
      .with(period: velocity.prior_period).returns(prior_window)

    result = velocity

    assert_in_delta 2_900 / 29.0 * DAYS_PER_MONTH, result.velocity.amount, 0.01
    assert_in_delta (2_900 / 29.0 - 580 / 29.0) * DAYS_PER_MONTH, result.momentum.amount, 0.01
  end

  test "a single-day period has no velocity" do
    track(history_from: @prior.start_date) { 10_000 }
    one_day = Period.custom(start_date: @today, end_date: @today)

    assert_nil BalanceSheet::NetWorthVelocity.new(BalanceSheet.new(@family), period: one_day).velocity
  end

  test "reads the period it is given, not today's date" do
    earlier = @today - 200
    track(history_from: earlier - 120, from: earlier - 120, to: @today) do |date|
      date <= earlier - 60 ? 1_000 : 1_000 + (date - (earlier - 60)).to_i * 10
    end
    period = Period.custom(start_date: earlier - 29, end_date: earlier)

    result = BalanceSheet::NetWorthVelocity.new(BalanceSheet.new(@family), period: period)

    assert_equal period.start_date - period.days, result.prior_period.start_date
    assert_not_nil result.velocity
    assert_not_nil result.momentum
  end

  private
    def velocity
      BalanceSheet::NetWorthVelocity.new(BalanceSheet.new(@family), period: @period)
    end

    # Net worth that gains `prior_gain` across the prior period and `current_gain`
    # across the current one, flat before and between.
    def level(date, prior_gain:, current_gain:)
      base = 10_000
      prior_progress = [ [ (date - @prior.start_date).to_i, 0 ].max, 29 ].min / 29.0
      current_progress = [ [ (date - @period.start_date).to_i, 0 ].max, 29 ].min / 29.0
      base + prior_gain * prior_progress + current_gain * current_progress
    end

    # One balance per day from `from` to `to`, and an opening-anchor entry on
    # `history_from` so the family has history exactly from then.
    def track(history_from:, from: nil, to: nil, &value)
      from ||= history_from
      to ||= @today
      @account.entries.create!(
        name: "Opening", date: history_from, amount: value.call(history_from), currency: "USD",
        entryable: Valuation.new(kind: "opening_anchor")
      )
      (from..to).each { |date| create_balance(account: @account, date: date, balance: value.call(date)) }
    end
end
