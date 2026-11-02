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

  test "the cache key reads no exchange rates when every account is in the target currency" do
    @family.accounts.update_all(currency: @family.currency)
    queries = exchange_rate_queries { builder.send(:cache_key, Period.last_30_days) }

    assert_empty queries, "the cache key scanned exchange_rates for a family that converts nothing"
  end

  test "the cache key follows the rates the series converts, and only those" do
    period = Period.last_30_days
    @family.accounts.update_all(currency: @family.currency)
    @asset_account.update_columns(currency: "EUR")
    ExchangeRate.create!(from_currency: "EUR", to_currency: @family.currency, date: 2.days.ago.to_date, rate: 1.1)
    k0 = BalanceSheet::NetWorthSeriesBuilder.new(@family.reload).send(:cache_key, period)

    travel 1.second do
      # A rate for a currency no account holds leaves the series alone ...
      ExchangeRate.create!(from_currency: "GBP", to_currency: @family.currency, date: Date.current, rate: 1.3)
      k1 = BalanceSheet::NetWorthSeriesBuilder.new(@family.reload).send(:cache_key, period)
      assert_equal k0, k1

      # ... one for the account's pair does not.
      ExchangeRate.create!(from_currency: "EUR", to_currency: @family.currency, date: Date.current, rate: 1.2)
      k2 = BalanceSheet::NetWorthSeriesBuilder.new(@family.reload).send(:cache_key, period)
      assert_not_equal k1, k2
    end
  end

  private
    def exchange_rate_queries(&block)
      queries = []
      callback = ->(*, payload) { queries << payload[:sql] if payload[:sql].match?(/\bexchange_rates\b/) }
      ActiveSupport::Notifications.subscribed(callback, "sql.active_record", &block)
      queries
    end

    def builder
      BalanceSheet::NetWorthSeriesBuilder.new(@family)
    end
end
