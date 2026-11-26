require "test_helper"

class BalanceSheet::NetWorthSeriesBuilderTest < ActiveSupport::TestCase
  include BalanceTestHelper

  setup do
    @family = families(:dylan_family)
    @asset_account = accounts(:depository)
    @liability_account = accounts(:credit_card)
  end

  test "net worth series cache key changes when the family currency changes" do
    period = Period.last_30_days
    before = builder.send(:cache_key, period)
    @family.update!(currency: "EUR")
    after = BalanceSheet::NetWorthSeriesBuilder.new(@family.reload).send(:cache_key, period)

    assert_not_equal before, after
  end

  # An account with no rate is left out of the series. A rate stored later,
  # by the market data import or a provider lookup on the balance sheet,
  # must reach the chart as it reaches the totals beside it.
  test "cache key changes when an exchange rate is stored" do
    period = Period.last_30_days
    before = BalanceSheet::NetWorthSeriesBuilder.new(@family).send(:cache_key, period)
    travel 1.second do
      ExchangeRate.create!(from_currency: "KRW", to_currency: @family.currency, date: Date.current, rate: 0.00075)
    end
    after = BalanceSheet::NetWorthSeriesBuilder.new(@family.reload).send(:cache_key, period)

    assert_not_equal before, after
  end

  test "net worth series cache key changes through the account deletion lifecycle and does not revert" do
    period = Period.last_30_days

    # Ensure @liability_account has the newest updated_at timestamp so deleting
    # @asset_account causes accounts.maximum(:updated_at) to revert to the same timestamp.
    @liability_account.touch
    k0 = builder.send(:cache_key, period)

    # Mark older account for deletion (K1)
    @asset_account.mark_for_deletion!
    k1 = BalanceSheet::NetWorthSeriesBuilder.new(@family.reload).send(:cache_key, period)

    # Destroy the account completely (K2, simulating DestroyJob)
    @asset_account.destroy!
    k2 = BalanceSheet::NetWorthSeriesBuilder.new(@family.reload).send(:cache_key, period)

    assert_not_equal k0, k1
    assert_not_equal k1, k2
    # Regression assertion for #4200: ensure key does not revert to pre-deletion state (k0)
    assert_not_equal k0, k2
  end

  test "passes the zero-balance cutoff to the chart" do
    @asset_account.balances.destroy_all
    create_balance(account: @asset_account, date: 10.days.ago.to_date, balance: 1000)
    create_balance(account: @asset_account, date: 5.days.ago.to_date, balance: 0)

    Balance::ChartSeriesBuilder.expects(:new)
      .with { |args| args[:account_active_until_dates][@asset_account.id] == 5.days.ago.to_date }
      .returns(stub(balance_series: :series))

    assert_equal :series, builder.net_worth_series
  end

  private
    def builder
      BalanceSheet::NetWorthSeriesBuilder.new(@family)
    end
end
