require "test_helper"

class IncomeStatement::DailyExpenseTotalsTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:empty)
    @checking = @family.accounts.create! name: "Checking", currency: @family.currency, balance: 5000, accountable: Depository.new
    @period = Period.custom(start_date: 9.days.ago.to_date, end_date: Date.current)
  end

  test "groups expense totals by day" do
    create_transaction(account: @checking, amount: 100, date: 2.days.ago.to_date)
    create_transaction(account: @checking, amount: 50, date: 2.days.ago.to_date)
    create_transaction(account: @checking, amount: 25, date: Date.current)

    series = daily_series
    by_date = series.index_by(&:date)

    assert_equal 2, series.size
    assert_equal 150, by_date[2.days.ago.to_date].total
    assert_equal 25, by_date[Date.current].total
  end

  test "excludes income, budget-excluded kinds, and pending transactions" do
    create_transaction(account: @checking, amount: -500, date: Date.current) # income
    create_transaction(account: @checking, amount: 40, date: Date.current, kind: "funds_movement")
    create_transaction(account: @checking, amount: 30, date: Date.current, kind: "cc_payment")
    pending_entry = create_transaction(account: @checking, amount: 20, date: Date.current)
    pending_entry.entryable.update!(extra: { "simplefin" => { "pending" => true } })
    create_transaction(account: @checking, amount: 10, date: Date.current)

    series = daily_series

    assert_equal 1, series.size
    assert_equal 10, series.first.total
  end

  test "excludes entries marked as excluded" do
    create_transaction(account: @checking, amount: 100, date: Date.current, excluded: true)
    create_transaction(account: @checking, amount: 10, date: Date.current)

    assert_equal 10, daily_series.first.total
  end

  test "counts loan payments and investment contributions as expenses" do
    create_transaction(account: @checking, amount: -200, date: Date.current, kind: "loan_payment")
    create_transaction(account: @checking, amount: -300, date: Date.current, kind: "investment_contribution")

    assert_equal 500, daily_series.first.total
  end

  test "converts foreign currency amounts at the day's exchange rate" do
    eur_account = @family.accounts.create! name: "EUR Checking", currency: "EUR", balance: 1000, accountable: Depository.new
    ExchangeRate.create! from_currency: "EUR", to_currency: @family.currency, date: Date.current, rate: 2

    create_transaction(account: eur_account, amount: 100, currency: "EUR", date: Date.current)

    assert_equal 200, daily_series.first.total
  end

  test "falls back to no conversion when the day's rate is missing" do
    eur_account = @family.accounts.create! name: "EUR Checking", currency: "EUR", balance: 1000, accountable: Depository.new

    create_transaction(account: eur_account, amount: 100, currency: "EUR", date: Date.current)

    assert_equal 100, daily_series.first.total
  end

  test "returns days in chronological order" do
    create_transaction(account: @checking, amount: 10, date: Date.current)
    create_transaction(account: @checking, amount: 20, date: 3.days.ago.to_date)

    assert_equal [ 3.days.ago.to_date, Date.current ], daily_series.map(&:date)
  end

  private
    def daily_series
      IncomeStatement.new(@family).daily_expense_series(period: @period)
    end
end
