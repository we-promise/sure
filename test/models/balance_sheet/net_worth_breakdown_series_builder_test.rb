require "test_helper"

class BalanceSheet::NetWorthBreakdownSeriesBuilderTest < ActiveSupport::TestCase
  include BalanceTestHelper

  setup do
    @family = families(:dylan_family)
    @family.accounts.each { |account| account.balances.destroy_all }

    @asset_account = accounts(:depository)
    @liability_account = accounts(:credit_card)
  end

  test "builds monthly points with group breakdown that sums to net worth" do
    period = Period.custom(start_date: 3.months.ago.to_date, end_date: Date.current)

    create_balance(account: @asset_account, date: period.start_date, balance: 5000)
    create_balance(account: @asset_account, date: Date.current, balance: 6000)
    create_balance(account: @liability_account, date: period.start_date, balance: 1000)
    create_balance(account: @liability_account, date: Date.current, balance: 1500)

    series = builder.breakdown_series(period: period)

    # One point per month in the period, end date included
    assert_equal 4, series[:values].size
    assert_equal period.start_date, series[:values].first[:date]
    assert_equal period.end_date, series[:values].last[:date]

    last_point = series[:values].last

    # Liabilities are reported as positive magnitudes
    assert_equal 6000, last_point[:assets].amount
    assert_equal 1500, last_point[:liabilities].amount
    assert_equal 4500, last_point[:value].amount

    # Every point's net worth equals assets minus liabilities
    series[:values].each do |point|
      assert_equal point[:value].amount, point[:assets].amount - point[:liabilities].amount
    end

    # Each point's trend is the month-over-month change from the previous
    # point; the first point has no prior month so its trend is flat
    assert_equal 0, series[:values].first[:trend].value.amount
    series[:values].each_cons(2) do |previous, point|
      assert_equal point[:value].amount - previous[:value].amount, point[:trend].value.amount
    end
  end

  test "includes group metadata and excludes groups with no balances" do
    period = Period.custom(start_date: 1.month.ago.to_date, end_date: Date.current)

    create_balance(account: @asset_account, date: Date.current, balance: 5000)
    create_balance(account: @liability_account, date: Date.current, balance: 1000)

    series = builder.breakdown_series(period: period)
    groups = series[:values].last[:groups]

    # Only account types with balances appear; assets sort before liabilities
    assert_equal [ "asset", "liability" ], groups.map { |g| g[:classification] }
    assert_equal Depository.display_name, groups.first[:name]
    assert_equal CreditCard.display_name, groups.last[:name]
    assert groups.all? { |g| g[:color].present? }
  end

  private
    def builder
      BalanceSheet::NetWorthBreakdownSeriesBuilder.new(@family)
    end
end
