require "test_helper"

class Reports::CategoryTrendTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:empty)
    @account = @family.accounts.create!(name: "Checking", currency: @family.currency,
                                        balance: 5000, accountable: Depository.new)
    @food = @family.categories.create!(name: "Food", color: "#111111")
    @groceries = @family.categories.create!(name: "Groceries", parent: @food, color: "#222222")
    @period = Period.custom(start_date: Date.new(2026, 1, 1), end_date: Date.new(2026, 3, 31))
  end

  test "nets a refund in the month it lands in" do
    create_transaction(account: @account, date: Date.new(2026, 1, 10), amount: 100, category: @groceries)
    create_transaction(account: @account, date: Date.new(2026, 1, 20), amount: -100, category: @groceries)
    create_transaction(account: @account, date: Date.new(2026, 3, 5), amount: 40, category: @groceries)

    series = trend(@groceries).series.sole

    assert_equal [ 0.0, 0.0, 40.0 ], series[:values].map { |point| point[:value] }
  end

  test "a refund without a purchase in the bucket plots below zero" do
    create_transaction(account: @account, date: Date.new(2026, 2, 5), amount: -30, category: @groceries)

    assert_equal(-30.0, trend(@groceries).series.sole[:values][1][:value])
  end

  test "tag ids limit the series to tagged transactions" do
    tag = @family.tags.create!(name: "Travel")
    create_transaction(account: @account, date: Date.new(2026, 1, 10), amount: 100, category: @groceries)
    create_transaction(account: @account, date: Date.new(2026, 1, 10), amount: 40, category: @groceries, tags: [ tag ])

    series = trend(@groceries, tag_ids: [ tag.id ]).series.sole

    assert_equal [ 40.0, 0.0, 0.0 ], series[:values].map { |point| point[:value] }
  end

  test "a parent series includes its subcategories, and a child alone does not" do
    create_transaction(account: @account, date: Date.new(2026, 1, 10), amount: 30, category: @groceries)
    create_transaction(account: @account, date: Date.new(2026, 1, 20), amount: 20, category: @food)

    parent = trend(@food).series.sole
    child = trend(@groceries).series.sole

    assert_equal 50.0, parent[:values].first[:value]
    assert_equal 30.0, child[:values].first[:value]
  end

  test "a custom range counts only the days inside it" do
    period = Period.custom(start_date: Date.new(2026, 1, 15), end_date: Date.new(2026, 3, 10))
    create_transaction(account: @account, date: Date.new(2026, 1, 5), amount: 70, category: @groceries)
    create_transaction(account: @account, date: Date.new(2026, 1, 20), amount: 10, category: @groceries)
    create_transaction(account: @account, date: Date.new(2026, 3, 20), amount: 70, category: @groceries)

    series = trend(@groceries, period: period).series.sole

    assert_equal [ 10.0, 0.0, 0.0 ], series[:values].map { |point| point[:value] }
  end

  test "year granularity sums the months in each calendar year" do
    period = Period.custom(start_date: Date.new(2025, 1, 1), end_date: Date.new(2026, 12, 31))
    create_transaction(account: @account, date: Date.new(2025, 2, 10), amount: 10, category: @groceries)
    create_transaction(account: @account, date: Date.new(2026, 2, 10), amount: 20, category: @groceries)

    series = trend(@groceries, period: period, granularity: "year").series.sole

    assert_equal [ 10.0, 20.0 ], series[:values].map { |point| point[:value] }
    assert_equal %w[2025 2026], series[:values].map { |point| point[:label] }
  end

  test "an entry in a currency with no rate is left out" do
    krw = @family.accounts.create!(name: "Seoul", currency: "KRW", balance: 0,
                                   accountable: Depository.new)
    create_transaction(account: krw, date: Date.new(2026, 1, 10), amount: 130_000,
                       currency: "KRW", category: @groceries)

    assert_equal 0.0, trend(@groceries).series.sole[:values].first[:value]
  end

  test "as_json carries the currency, granularity and one value per bucket" do
    create_transaction(account: @account, date: Date.new(2026, 1, 10), amount: 10, category: @groceries)

    json = trend(@groceries).as_json

    assert_equal @family.currency, json[:currency]
    assert_equal "month", json[:granularity]
    assert_equal 3, json[:series].sole[:values].size
    assert_equal "2026-01-01", json[:series].sole[:values].first[:date]
  end

  private
    def trend(*categories, period: @period, granularity: "month", tag_ids: nil)
      selection = Reports::CategorySelection.new(@family, categories.map { |category| category.id.to_s })
      Reports::CategoryTrend.new(IncomeStatement.new(@family), period: period, selection: selection,
                                 granularity: granularity, tag_ids: tag_ids)
    end
end
