require "test_helper"

# Report queries look each (currency, date) up once through the fx_rates CTE
# instead of calling ExchangeRate.rate_sql per entry. They must convert every
# entry as rate_sql does: the latest stored rate on or before its date, else
# the earliest after it, else leave it out.
class IncomeStatement::FxRatesTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    travel_to Date.new(2026, 7, 15)

    @family = families(:empty)
    @family.update!(currency: "USD")
    @food = @family.categories.create!(name: "Food")
    @usd = account("USD")
    @eur = account("EUR")
    @gbp = account("GBP")
    @jpy = account("JPY")

    ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", date: Date.new(2026, 6, 10), rate: 1.5)
    ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", date: Date.new(2026, 6, 15), rate: 2)
    ExchangeRate.create!(from_currency: "GBP", to_currency: "USD", date: Date.new(2026, 6, 19), rate: 1.25)

    spend(@eur, 10, Date.new(2026, 6, 10))   # on a rate's date: 15
    spend(@eur, 20, Date.new(2026, 6, 12))   # between rates, the earlier one: 30
    spend(@eur, 40, Date.new(2026, 6, 15))   # two entries on one date: 80
    spend(@eur, 5, Date.new(2026, 6, 15))    # ...and 10
    spend(@gbp, 8, Date.new(2026, 6, 16))    # no earlier rate, the later one: 10
    spend(@jpy, 1000, Date.new(2026, 6, 15)) # no rate at all: left out
    spend(@usd, 7, Date.new(2026, 6, 15))    # the family's currency: 7
    spend(@eur, -50, Date.new(2026, 6, 15))  # income: 100

    @period = Period.custom(start_date: Date.new(2026, 6, 1), end_date: Date.new(2026, 6, 30))
  end

  teardown { travel_back }

  test "the expected amounts are what rate_sql gives entry by entry" do
    assert_equal BigDecimal("152"), rate_sql_total { |entries| entries.where("entries.amount > 0") }
    assert_equal BigDecimal("-100"), rate_sql_total { |entries| entries.where("entries.amount < 0") }
  end

  test "income statement totals convert each entry as rate_sql does" do
    statement = IncomeStatement.new(@family)

    assert_equal BigDecimal("152"), statement.expense_totals(period: @period).total
    assert_equal BigDecimal("100"), statement.income_totals(period: @period).total
  end

  test "daily expense totals convert each entry as rate_sql does" do
    days = IncomeStatement::DailyExpenseTotals.new(
      @family,
      transactions_scope: @family.transactions.visible.excluding_pending.in_period(@period),
      date_range: @period.date_range
    ).call

    assert_equal BigDecimal("152"), days.sum(&:total)
    assert_equal BigDecimal("97"), days.find { |day| day.date == Date.new(2026, 6, 15) }.total
  end

  test "monthly stats convert each entry as rate_sql does" do
    expense = IncomeStatement::FamilyStats.new(@family, interval: "month").call.find { |row| row.classification == "expense" }

    assert_equal BigDecimal("152"), expense.median.to_d
  end

  test "transaction search totals convert each entry as rate_sql does" do
    totals = Transaction::Search.new(@family, filters: {}).totals

    assert_equal Money.new(152, "USD"), totals.expense_money
    assert_equal Money.new(100, "USD"), totals.income_money
  end

  test "a transactions scope that doesn't join entries is rejected" do
    totals = IncomeStatement::Totals.new(
      @family,
      transactions_scope: Transaction.where(id: @family.transactions.select(:id)),
      date_range: @period.date_range
    )

    error = assert_raises(ArgumentError) { totals.call }
    assert_match "must join entries", error.message
  end

  private
    def account(currency)
      @family.accounts.create!(name: "#{currency} account", currency: currency, balance: 0, accountable: Depository.new)
    end

    def spend(account, amount, date)
      create_transaction(account: account, amount: amount, currency: account.currency, date: date, category: @food)
    end

    def rate_sql_total
      rate = ExchangeRate.rate_sql(from: "entries.currency", to: "'USD'", on: "entries.date")
      entries = yield Entry.joins(:account).where(accounts: { family_id: @family.id })
      entries.pick(Arel.sql("SUM(entries.amount * #{rate})")).to_d
    end
end
