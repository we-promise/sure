require "test_helper"

class RecurringTransaction::ForecastTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @user = users(:family_admin)
    @family.recurring_transactions.destroy_all
  end

  test "defaults to the next 10 days and never starts before today" do
    forecast = forecast_with(start_date: 1.month.ago.to_date.iso8601)

    assert_equal Date.current, forecast.start_date
    assert_equal Date.current + 10, forecast.end_date
  end

  test "lists each due date within the filter's date range" do
    first_due = Date.current.next_month.beginning_of_month
    rent = create_series(name: "Rent", next_expected_date: first_due)

    forecast = forecast_with(start_date: (first_due + 1.day).iso8601, end_date: (first_due + 2.months).iso8601)

    assert_equal [ first_due + 1.month, first_due + 2.months ], forecast.occurrences.map(&:date)
    assert_equal [ rent ], forecast.occurrences.map(&:series).uniq
  end

  test "applies the list's account, category, merchant, type, search and amount filters" do
    due = 3.days.from_now.to_date
    rent = create_series(name: "Rent", amount: 1500, next_expected_date: due, category: categories(:subcategory))
    salary = create_series(name: "Salary", amount: -4000, next_expected_date: due)
    netflix = create_series(name: "Streaming", amount: 15, next_expected_date: due,
      merchant: merchants(:netflix), account: accounts(:credit_card))

    assert_series [ netflix ], accounts: [ accounts(:credit_card).name ]
    assert_series [ rent ], categories: [ categories(:food_and_drink).name ]
    assert_series [ netflix ], merchants: [ "Netflix" ]
    assert_series [ salary ], types: [ "income" ]
    assert_series [ rent, netflix ], types: [ "expense" ]
    assert_series [ netflix ], search: "netf"
    assert_series [ rent, salary ], amount: "1000", amount_operator: "greater"
  end

  test "totals split income and expense, converted to the family currency, without transfers" do
    due = 3.days.from_now.to_date
    ExchangeRate.create!(from_currency: "EUR", to_currency: @family.currency, date: Date.current, rate: 2)
    create_series(name: "Rent", amount: 1000, next_expected_date: due)
    create_series(name: "Gym", amount: 50, currency: "EUR", next_expected_date: due)
    create_series(name: "Salary", amount: -3000, next_expected_date: due)
    create_series(name: "Savings", amount: 500, next_expected_date: due, destination_account: accounts(:credit_card))

    totals = forecast_with.totals

    assert_equal 4, totals.count
    assert_equal Money.new(3000, @family.currency), totals.income_money
    assert_equal Money.new(1100, @family.currency), totals.expense_money
  end

  test "reports the filters that only apply to posted transactions" do
    assert_equal %w[tags status], forecast_with(tags: [ "Trip" ], status: [ "pending" ], search: "rent").ignored_filters
  end

  private
    def forecast_with(**filters)
      RecurringTransaction::Forecast.new(@family, user: @user, filters: filters)
    end

    def assert_series(expected, **filters)
      assert_equal expected.map(&:id).sort, forecast_with(**filters).series.map(&:id).sort, filters.inspect
    end

    def create_series(name:, next_expected_date:, amount: 100, currency: @family.currency, account: accounts(:depository), **attrs)
      @family.recurring_transactions.create!(
        name: name, amount: amount, currency: currency, account: account, status: "active",
        expected_day_of_month: next_expected_date.day, last_occurrence_date: next_expected_date - 1.month,
        next_expected_date: next_expected_date, **attrs
      )
    end
end
