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

  test "zero-balance accounts stop at their last balance entry" do
    account = accounts(:depository)
    account.balances.destroy_all
    create_balance(account: account, date: 10.days.ago.to_date, balance: 1000)
    create_balance(account: account, date: 5.days.ago.to_date, balance: 0)

    assert_equal 5.days.ago.to_date, builder.send(:account_active_until_dates)[account.id]
  end

  test "accounts still holding a balance stay in the chart" do
    account = accounts(:depository)
    account.balances.destroy_all
    create_balance(account: account, date: 5.days.ago.to_date, balance: 0)
    create_balance(account: account, date: 1.day.ago.to_date, balance: 500)

    assert_not_includes builder.send(:account_active_until_dates), account.id
  end

  test "a disabled account keeps the earlier cutoff" do
    account = accounts(:depository)
    account.balances.destroy_all
    account.update_columns(status: "disabled", disabled_at: 3.days.ago)
    create_balance(account: account, date: 1.day.ago.to_date, balance: 0)

    assert_equal 4.days.ago.to_date, builder.send(:account_active_until_dates)[account.id]
  end

  test "a zero balance can stop a disabled account before it was disabled" do
    account = accounts(:depository)
    account.balances.destroy_all
    account.update_columns(status: "disabled", disabled_at: 3.days.ago)
    create_balance(account: account, date: 10.days.ago.to_date, balance: 0)

    assert_equal 10.days.ago.to_date, builder.send(:account_active_until_dates)[account.id]
  end

  private
    def builder
      BalanceSheet::NetWorthSeriesBuilder.new(@family)
    end
end
