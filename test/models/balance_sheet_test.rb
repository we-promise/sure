require "test_helper"

class BalanceSheetTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
  end

  test "calculates total assets" do
    assert_equal 0, BalanceSheet.new(@family).assets.total

    create_account(balance: 1000, accountable: Depository.new)
    create_account(balance: 5000, accountable: OtherAsset.new)
    create_account(balance: 10000, accountable: CreditCard.new) # ignored

    assert_equal 1000 + 5000, BalanceSheet.new(@family).assets.total
  end

  test "calculates total liabilities" do
    assert_equal 0, BalanceSheet.new(@family).liabilities.total

    create_account(balance: 1000, accountable: CreditCard.new)
    create_account(balance: 5000, accountable: OtherLiability.new)
    create_account(balance: 10000, accountable: Depository.new) # ignored

    assert_equal 1000 + 5000, BalanceSheet.new(@family).liabilities.total
  end

  test "calculates net worth" do
    assert_equal 0, BalanceSheet.new(@family).net_worth

    create_account(balance: 1000, accountable: CreditCard.new)
    create_account(balance: 50000, accountable: Depository.new)

    assert_equal 50000 - 1000, BalanceSheet.new(@family).net_worth
  end

  test "disabled accounts do not affect totals" do
    create_account(balance: 1000, accountable: CreditCard.new)
    create_account(balance: 10000, accountable: Depository.new)

    other_liability = create_account(balance: 5000, accountable: OtherLiability.new)
    other_liability.disable!

    assert_equal 10000 - 1000, BalanceSheet.new(@family).net_worth
    assert_equal 10000, BalanceSheet.new(@family).assets.total
    assert_equal 1000, BalanceSheet.new(@family).liabilities.total
  end

  test "cache key only considers visible accounts" do
    # Create active and disabled accounts
    active_account = create_account(balance: 1000, accountable: Depository.new)
    disabled_account = create_account(balance: 5000, accountable: Depository.new)
    disabled_account.disable!

    # Get initial cache key
    initial_totals = BalanceSheet::AccountTotals.new(@family, sync_status_monitor: BalanceSheet::SyncStatusMonitor.new(@family))
    initial_cache_key = initial_totals.send(:cache_key)

    # Travel forward in time and update disabled account - cache key should NOT change
    travel 1.minute do
      disabled_account.touch
      same_cache_key = BalanceSheet::AccountTotals.new(@family, sync_status_monitor: BalanceSheet::SyncStatusMonitor.new(@family)).send(:cache_key)

      assert_equal initial_cache_key, same_cache_key, "Cache key should not change when only disabled account is updated"
    end

    # Travel further forward and update active account - cache key SHOULD change
    travel 2.minutes do
      active_account.touch
      new_cache_key = BalanceSheet::AccountTotals.new(@family, sync_status_monitor: BalanceSheet::SyncStatusMonitor.new(@family)).send(:cache_key)

      assert_not_equal initial_cache_key, new_cache_key, "Cache key should change when visible account is updated"
    end
  end

  test "disabled account updates do not invalidate balance sheet cache" do
    # Create accounts
    active_account = create_account(balance: 1000, accountable: Depository.new)
    disabled_account = create_account(balance: 5000, accountable: Depository.new)
    disabled_account.disable!

    # Access balance sheet to populate cache
    balance_sheet = BalanceSheet.new(@family)
    initial_total = balance_sheet.assets.total
    assert_equal 1000, initial_total

    # Update disabled account's balance in the database directly
    disabled_account.update_column(:balance, 10000)

    # Create new balance sheet - should still use cached data since cache key didn't change
    balance_sheet2 = BalanceSheet.new(@family)
    assert_equal 1000, balance_sheet2.assets.total, "Total should not include disabled account even after direct balance update"
  end

  test "calculates asset group totals" do
    create_account(balance: 1000, accountable: Depository.new)
    create_account(balance: 2000, accountable: Depository.new)
    create_account(balance: 3000, accountable: Investment.new)
    create_account(balance: 5000, accountable: OtherAsset.new)
    create_account(balance: 10000, accountable: CreditCard.new) # ignored

    asset_groups = BalanceSheet.new(@family).assets.account_groups

    assert_equal 3, asset_groups.size
    assert_equal 1000 + 2000, asset_groups.find { |ag| ag.name == I18n.t("accounts.types.depository") }.total
    assert_equal 3000, asset_groups.find { |ag| ag.name == I18n.t("accounts.types.investment") }.total
    assert_equal 5000, asset_groups.find { |ag| ag.name == I18n.t("accounts.types.other_asset") }.total
  end

  test "calculates liability group totals" do
    create_account(balance: 1000, accountable: CreditCard.new)
    create_account(balance: 2000, accountable: CreditCard.new)
    create_account(balance: 3000, accountable: OtherLiability.new)
    create_account(balance: 5000, accountable: OtherLiability.new)
    create_account(balance: 10000, accountable: Depository.new) # ignored

    liability_groups = BalanceSheet.new(@family).liabilities.account_groups

    assert_equal 2, liability_groups.size
    assert_equal 1000 + 2000, liability_groups.find { |ag| ag.name == I18n.t("accounts.types.credit_card") }.total
    assert_equal 3000 + 5000, liability_groups.find { |ag| ag.name == I18n.t("accounts.types.other_liability") }.total
  end

  private
    def create_account(attributes = {})
      account = @family.accounts.create! name: "Test", currency: "USD", **attributes
      account
    end
end
