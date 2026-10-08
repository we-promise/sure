require "test_helper"

class Portfolio::IncomeTest < ActiveSupport::TestCase
  include PortfolioReturnsTestHelper

  setup do
    @family = families(:empty) # USD
    @account = create_portfolio_account(family: @family)
    @feb = Date.new(2026, 2, 27)
    @mar = Date.new(2026, 3, 2)
    @last_day = Date.new(2026, 4, 2)
  end

  # The reason the series is built on
  # the daily rows rather than on either storage shape: a Trade-shaped dividend
  # (qty 0, since #1311) and a Transaction-shaped one (Trading212,
  # SimpleFIN) in the SAME month have to land in the same bucket.
  test "a trade-shaped and a transaction-shaped dividend both reach the month's total" do
    income_trade account: @account, date: @mar, amount: 30
    income_transaction account: @account, date: @mar + 1, amount: 12.5
    lay_flat_balances cash_by_date: { @mar => 30, @mar + 1 => 12.5 }

    income = income_for

    assert_equal [ Date.new(2026, 3, 1) ], income.buckets.map(&:month)
    assert_equal BigDecimal("42.5"), income.buckets.first.amount,
                 "the month holds both shapes -- dropping either reads 30 or 12.5"
    assert_equal BigDecimal("42.5"), income.total
  end

  # Interest is income exactly as a dividend is (FlowClassifier LABEL_RULES),
  # and it has to land in the same figure rather than a second one.
  test "interest is counted with dividends" do
    income_trade account: @account, date: @mar, amount: 30, label: "Dividend"
    income_transaction account: @account, date: @mar, amount: 5, label: "Interest"
    lay_flat_balances cash_by_date: { @mar => 35 }

    income = income_for

    assert_equal [ Date.new(2026, 3, 1) ], income.buckets.map(&:month)
    assert_equal BigDecimal(35), income.buckets.first.amount,
                 "both labels land in the one March bucket; `total` alone would pass with two buckets"
    assert_equal BigDecimal(35), income.total
  end

  # Neither shape is a contribution. The classifier already guarantees it; this
  # is what stops a reader that groups the rows differently from re-deriving
  # the answer and counting a payout as money the user paid in.
  test "income is not a contribution or a withdrawal, and reconciles with the drivers" do
    income_trade account: @account, date: @mar, amount: 30
    income_transaction account: @account, date: @mar + 1, amount: 12.5
    lay_flat_balances cash_by_date: { @mar => 30, @mar + 1 => 12.5 }

    returns = daily_returns
    drivers = Portfolio::Drivers.new(returns)
    income = Portfolio::Income.new(returns)

    assert_equal BigDecimal(0), drivers.external_net
    assert_equal drivers.income, income.total,
                 "the bars and the drivers table are the same rows and have to agree"
    assert drivers.reconciles?, "regrouping the rows must not change what they add up to"
  end

  # An empty bar and a break-even month are different facts.
  test "a month with no income is absent rather than zero" do
    income_trade account: @account, date: @feb, amount: 10
    income_trade account: @account, date: Date.new(2026, 4, 1), amount: 20
    lay_flat_balances cash_by_date: { @feb => 10, Date.new(2026, 4, 1) => 20 }

    income = income_for

    assert_equal [ Date.new(2026, 2, 1), Date.new(2026, 4, 1) ], income.buckets.map(&:month),
                 "March earned nothing and has no bar"
    assert_equal [ BigDecimal(10), BigDecimal(20) ], income.buckets.map(&:amount)
  end

  # A reversal is a dividend row with the opposite sign. A month that paid 10
  # and had 10 clawed back was an active month, and a chart that omits it says
  # nothing happened. The bucket stays, at zero, and the buckets still add up to
  # the total.
  test "a month whose payments and reversals net to zero is kept" do
    income_trade account: @account, date: @mar, amount: 10
    income_trade account: @account, date: @mar + 1, amount: -10
    lay_flat_balances cash_by_date: { @mar => 10, @mar + 1 => -10 }

    income = income_for

    assert_equal [ Date.new(2026, 3, 1) ], income.buckets.map(&:month)
    assert_equal BigDecimal(0), income.buckets.first.amount
    assert income.any?, "a month with activity is not a period with no income"
    assert_equal income.total, income.buckets.sum(BigDecimal(0), &:amount)
  end

  test "a month that nets negative keeps its sign, so the buckets still add up to the total" do
    income_trade account: @account, date: @feb, amount: 5
    income_trade account: @account, date: @mar, amount: -8
    lay_flat_balances cash_by_date: { @feb => 5, @mar => -8 }

    income = income_for

    assert_equal [ BigDecimal(5), BigDecimal(-8) ], income.buckets.map(&:amount)
    assert_equal BigDecimal(-3), income.total
  end

  test "a period with no income has no buckets and a zero total" do
    lay_flat_balances cash_by_date: {}

    income = income_for

    assert_empty income.buckets
    assert_equal BigDecimal(0), income.total
    assert_not income.any?
  end

  # A fee is not negative income. Folding it into the bar would hide the cost
  # inside the payout it was charged against.
  test "a fee is reported separately and does not reduce income" do
    income_trade account: @account, date: @mar, amount: 30
    fee_entry account: @account, date: @mar, amount: 4
    lay_flat_balances cash_by_date: { @mar => 26 }

    income = income_for

    assert_equal BigDecimal(30), income.total
    assert_equal BigDecimal(4), income.fees
  end

  # Today's value is deliberately different and much larger: a
  # ratio taken over the closing balance reads 10 / 3_000, one taken over the
  # opening balance 10 / 1_000, and only the average of the period is 10 / 2_000.
  test "the fee ratio divides by the period's value, not by where it ended" do
    fee_entry account: @account, date: @feb + 1, amount: 10
    lay_balance account: @account, date: @feb, opening: 1_000, closing: 1_000
    lay_balance account: @account, date: @feb + 1, opening: 1_000, closing: 990, cash_flow: -10
    lay_balance account: @account, date: @feb + 2, opening: 990, closing: 3_010, market_flow: 2_020

    income = Portfolio::Income.new(
      Portfolio::DailyReturns.new(
        account_ids: [ @account.id ], currency: @family.currency,
        period: Period.custom(start_date: @feb, end_date: @feb + 2)
      )
    )

    assert_equal BigDecimal(10), income.fees
    expected_average = (BigDecimal(1_000) + 990 + 3_010) / 3
    assert_equal expected_average, income.average_value
    assert_in_delta 10 / expected_average, income.fee_ratio, BigDecimal("1e-12")
  end

  # No value to divide by is no ratio -- not a ratio of zero.
  test "the fee ratio is nil when the period holds no value" do
    lay_flat_balances cash_by_date: {}, balance: 0

    assert_nil income_for.fee_ratio
  end

  # Income converts the way every other flow in the daily rows does: at the
  # PREVIOUS day's rate (see Portfolio::DailyReturns), so the local
  # components and the currency effect add up exactly. The rate on the payment
  # day and every later day is deliberately different, so a conversion at either
  # reads 20 rather than 15.
  test "a foreign currency dividend converts at the rate of the day before it was paid" do
    eur = create_portfolio_account(family: @family, currency: "EUR")
    income_trade account: eur, date: @mar, amount: 10
    (@feb..@last_day).each do |date|
      cash = date == @mar ? 10 : 0
      lay_balance account: eur, date: date, opening: 1_000 + (date > @mar ? 10 : 0), closing: 1_000 + (date >= @mar ? 10 : 0), cash_flow: cash
      set_rate from: "EUR", to: "USD", date: date, rate: date == @mar - 1 ? 1.5 : 2.0
    end

    income = Portfolio::Income.new(
      Portfolio::DailyReturns.new(
        account_ids: [ eur.id ], currency: "USD",
        period: Period.custom(start_date: @feb, end_date: @last_day)
      )
    )

    assert_equal BigDecimal(15), income.total
  end

  private
    def daily_returns
      Portfolio::DailyReturns.new(
        account_ids: [ @account.id ],
        currency: @family.currency,
        period: Period.custom(start_date: @feb, end_date: @last_day)
      )
    end

    def income_for
      Portfolio::Income.new(daily_returns)
    end

    # One balance row for every day of the period. `cash_by_date` is the cash
    # that arrived (or left) on a day, so the balance steps by exactly what the
    # entries moved and the day's components still add up to its change.
    def lay_flat_balances(cash_by_date:, balance: 1_000)
      running = BigDecimal(balance)

      (@feb..@last_day).each do |date|
        flow = BigDecimal(cash_by_date.fetch(date, 0).to_s)
        lay_balance account: @account, date: date, opening: running, closing: running + flow, cash_flow: flow
        running += flow
      end
    end
end
