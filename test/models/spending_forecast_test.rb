require "test_helper"

class SpendingForecastTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    travel_to Date.new(2026, 4, 15)

    @family = families(:empty)
    @account = @family.accounts.create!(name: "Checking", currency: @family.currency, balance: 5000, accountable: Depository.new)
    @food = @family.categories.create!(name: "Food")
    @groceries = @family.categories.create!(name: "Groceries", parent: @food)
    @travel = @family.categories.create!(name: "Travel")
    @housing = @family.categories.create!(name: "Housing")
  end

  test "predicts each category's median month less what it has spent this month" do
    spend(@groceries, 100, Date.new(2026, 1, 1))
    spend(@groceries, 200, Date.new(2026, 2, 10))
    spend(@food, 300, Date.new(2026, 3, 10))
    spend(@groceries, 50, Date.new(2026, 4, 5))
    # One trip in three months is not a monthly habit.
    spend(@travel, 900, Date.new(2026, 2, 20))

    forecast = SpendingForecast.new(@family)

    assert_equal 3, forecast.history_months
    assert_equal [ @food ], forecast.rows.map(&:category)

    row = forecast.rows.first
    assert_equal 200, row.typical.amount
    assert_equal 50, row.spent.amount
    assert_equal 150, row.remaining.amount
    assert_equal 150, forecast.remaining_this_month.amount
    assert_equal 200, forecast.next_month.amount
  end

  test "leaves out transactions matched to a bill" do
    spend(@groceries, 100, Date.new(2026, 1, 1))
    rent_entries = (1..3).map { |month| spend(@housing, 1000, Date.new(2026, month, 1)) }
    match_to_bill(rent_entries)

    assert_equal [ @food ], SpendingForecast.new(@family).rows.map(&:category)
  end

  test "skips the partial first month of history" do
    spend(@groceries, 100, Date.new(2026, 3, 10))

    forecast = SpendingForecast.new(@family)

    assert_equal 0, forecast.history_months
    assert_not forecast.any?
  end

  private
    def spend(category, amount, date)
      create_transaction(account: @account, amount: amount, currency: @family.currency, date: date, category: category)
    end

    def match_to_bill(entries)
      series = @family.recurring_transactions.create!(
        name: "Rent", account: @account, amount: 1000, currency: @family.currency,
        expected_day_of_month: 1, last_occurrence_date: entries.last.date,
        next_expected_date: Date.new(2026, 5, 1), status: "active", manual: true
      )

      entries.each do |entry|
        occurrence = series.recurring_occurrences.create!(family: @family, original_due_on: entry.date, due_on: entry.date, currency: @family.currency)
        RecurringAllocation.create!(
          recurring_occurrence: occurrence, entry: entry, state: :confirmed, source: :user_confirmed,
          allocated_amount: 1000, currency: @family.currency, paid_on: entry.date
        )
      end
    end
end
