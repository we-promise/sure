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

  test "projects from the schedule when the cached next date has fallen behind" do
    travel_to Date.new(2026, 8, 13) do
      create_series(name: "Stale", next_expected_date: Date.new(2026, 6, 5))

      assert_equal [ Date.new(2026, 9, 5) ], forecast_with(end_date: "2026-09-30").occurrences.map(&:date)
    end
  end

  test "projects from the schedule when the cached next date skipped this month" do
    travel_to Date.new(2026, 8, 13) do
      create_series(name: "Rent", next_expected_date: Date.new(2026, 9, 29), last_occurrence_date: Date.new(2026, 8, 6))

      assert_equal [ Date.new(2026, 8, 29) ], forecast_with(end_date: "2026-08-31").occurrences.map(&:date)
    end
  end

  test "falls back to the cached next date for a series with nothing stored" do
    series = create_series(name: "Legacy", next_expected_date: 4.days.from_now.to_date)
    series.recurring_occurrences.delete_all

    assert_equal [ 4.days.from_now.to_date ], dates_for(forecast_with, series)
  end

  test "skips a cycle already paid and uses an open occurrence's snoozed date" do
    travel_to Date.new(2026, 8, 13) do
      paid_early = create_series(name: "Paid early", next_expected_date: Date.new(2026, 8, 20))
      stored_occurrence(paid_early, Date.new(2026, 8, 20)).update!(status: "paid", closed_at: Time.current)
      snoozed = create_series(name: "Snoozed", next_expected_date: Date.new(2026, 8, 21))
      stored_occurrence(snoozed, Date.new(2026, 8, 21)).update!(snoozed_until: Date.new(2026, 8, 26))

      forecast = forecast_with(end_date: "2026-09-30")

      assert_equal [ Date.new(2026, 9, 20) ], dates_for(forecast, paid_early)
      assert_equal [ Date.new(2026, 8, 26), Date.new(2026, 9, 21) ], dates_for(forecast, snoozed)
    end
  end

  test "keeps a snoozed occurrence that lands on the next cycle's date as its own bill" do
    travel_to Date.new(2026, 8, 13) do
      series = create_series(name: "Snoozed", next_expected_date: Date.new(2026, 8, 21))
      stored_occurrence(series, Date.new(2026, 8, 21)).update!(snoozed_until: Date.new(2026, 9, 21))

      forecast = forecast_with(end_date: "2026-09-30")

      assert_equal [ Date.new(2026, 9, 21), Date.new(2026, 9, 21) ], dates_for(forecast, series)
      assert_equal 2, forecast.totals.count
      assert_equal Money.new(200, @family.currency), forecast.totals.expense_money
    end
  end

  test "does not continue the schedule into a stored cycle moved off the weekend" do
    travel_to Date.new(2026, 8, 13) do
      # 2026-08-22 is a Saturday; the occurrence is due Monday 2026-08-24.
      series = create_series(name: "Weekend", next_expected_date: Date.new(2026, 8, 24), expected_day_of_month: 22, last_occurrence_date: Date.new(2026, 7, 22),
                             weekend_adjust: "after")
      saturday = stored_occurrence(series, Date.new(2026, 8, 22))
      assert_equal Date.new(2026, 8, 24), saturday.due_on
      saturday.update!(status: "paid", closed_at: Time.current)
      series.recurring_occurrences.where("original_due_on > ?", saturday.original_due_on).delete_all

      assert_equal [ Date.new(2026, 9, 22) ], dates_for(forecast_with(end_date: "2026-09-30"), series)
    end
  end

  test "leaves out disabled accounts unless active_accounts_only is off, as the list does" do
    account = accounts(:credit_card)
    series = create_series(name: "Old card fee", next_expected_date: 3.days.from_now.to_date, account: account)
    account.update_columns(status: "disabled")

    assert_not_includes forecast_with.series, series
    assert_includes forecast_with(active_accounts_only: "false").series, series
  end

  test "matches a transfer on its destination account" do
    transfer = create_series(name: "Savings", next_expected_date: 3.days.from_now.to_date,
      destination_account: accounts(:credit_card))

    assert_includes forecast_with(account_ids: [ accounts(:credit_card).id ]).series, transfer
    assert_includes forecast_with(accounts: [ accounts(:credit_card).name ]).series, transfer
  end

  test "filters on the amount a manual series shows" do
    series = create_series(name: "Power", amount: 50, next_expected_date: 3.days.from_now.to_date,
      manual: true, expected_amount_avg: 120)

    assert_includes forecast_with(amount: "100", amount_operator: "greater").series, series
    assert_not_includes forecast_with(amount: "100", amount_operator: "less").series, series
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

  test "combines the filtered actuals with the forecast" do
    create_series(name: "Rent", amount: 1000, next_expected_date: 3.days.from_now.to_date)
    actual = Transaction::Search.new(@family).totals

    combined = forecast_with.combined_with(actual, 7)

    assert_equal 8, combined.count
    assert_equal actual.expense_money + Money.new(1000, @family.currency), combined.expense_money
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
      @family.recurring_transactions.create!({
        name: name, amount: amount, currency: currency, account: account, status: "active",
        expected_day_of_month: next_expected_date.day, last_occurrence_date: next_expected_date - 1.month,
        next_expected_date: next_expected_date
      }.merge(attrs))
    end

    # Creating a series materializes its occurrences.
    def stored_occurrence(series, original_due_on)
      series.recurring_occurrences.find_by!(original_due_on: original_due_on)
    end

    def dates_for(forecast, series)
      forecast.occurrences.select { |occurrence| occurrence.series == series }.map(&:date)
    end
end
