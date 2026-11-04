require "test_helper"

class BalanceSheetTest < ActiveSupport::TestCase
  include BalanceTestHelper

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

  test "excluded accounts do not affect totals" do
    create_account(balance: 1000, accountable: CreditCard.new)
    create_account(balance: 10000, accountable: Depository.new)

    excluded_asset = create_account(balance: 5000, accountable: Depository.new)
    excluded_asset.update!(exclude_from_reports: true)

    assert_equal 10000 - 1000, BalanceSheet.new(@family).net_worth
    assert_equal 10000, BalanceSheet.new(@family).assets.total
    assert_equal 1000, BalanceSheet.new(@family).liabilities.total
  end

  test "excluded accounts still have their own balance in account groups" do
    create_account(balance: 1000, accountable: Depository.new)
    excluded_asset = create_account(balance: 5000, accountable: Depository.new)
    excluded_asset.update!(exclude_from_reports: true)

    asset_groups = BalanceSheet.new(@family).assets.account_groups
    depository_group = asset_groups.find { |ag| ag.name == Depository.display_name }

    assert_equal 1000, depository_group.total
    assert depository_group.accounts.any?(&:exclude_from_reports?)
  end

  test "net worth series preserves disabled history without carrying it into current totals" do
    period = Period.custom(start_date: Date.current - 1.day, end_date: Date.current)
    active_account = create_account(balance: 20_000, accountable: Depository.new)
    disabled_account = create_account(balance: 0, accountable: Depository.new)
    pending_deletion_account = create_account(balance: 0, accountable: Depository.new)
    disabled_account.disable!
    pending_deletion_account.mark_for_deletion!

    assert_not_nil disabled_account.reload.disabled_at

    create_balance(account: active_account, date: period.start_date, balance: 10_000)
    create_balance(account: active_account, date: period.end_date, balance: 20_000)
    create_balance(account: disabled_account, date: period.start_date, balance: 20_000)
    create_balance(account: disabled_account, date: period.end_date, balance: 10_000)
    create_balance(account: pending_deletion_account, date: period.start_date, balance: 40_000)
    create_balance(account: pending_deletion_account, date: period.end_date, balance: 80_000)

    series = BalanceSheet.new(@family).net_worth_series(period: period)
    values_by_date = series.values.index_by(&:date)

    assert_equal 30_000, values_by_date.fetch(period.start_date).value.amount
    assert_equal 20_000, BalanceSheet.new(@family).net_worth
    assert_equal BalanceSheet.new(@family).net_worth, values_by_date.fetch(period.end_date).value.amount
  end

  # A failed delete restores the account to disabled. Its history must still
  # stop where it was disabled, not run on to the failure.
  test "a failed destroy of a disabled account keeps its net worth cutoff" do
    period = Period.custom(start_date: Date.current - 3.days, end_date: Date.current)
    active_account = create_account(balance: 1_000, accountable: Depository.new)
    disabled_account = create_account(balance: 0, accountable: Depository.new)
    create_balance(account: active_account, date: period.start_date, balance: 1_000)
    create_balance(account: active_account, date: period.end_date, balance: 1_000)
    create_balance(account: disabled_account, date: period.start_date, balance: 20_000)
    disabled_account.update_columns(status: "disabled", disabled_at: 10.days.ago)

    start_value = -> { BalanceSheet.new(@family).net_worth_series(period: period).values.index_by(&:date).fetch(period.start_date).value.amount }
    assert_equal 1_000, start_value.call

    disabled_account.mark_for_deletion!
    disabled_account.stubs(:cleanup_transfers).raises(StandardError, "destroy failed")
    assert_raises(StandardError) { disabled_account.destroy }
    assert disabled_account.reload.disabled?
    Rails.cache.clear

    assert_equal 1_000, start_value.call
  end

  # An active account can still carry a disabled_at from being disabled and
  # enabled again before enable cleared it. A failed delete must not turn that
  # stale date into its cutoff and drop the stretch in which it was active.
  test "a failed destroy of an active account with a stale disabled_at keeps its history" do
    period = Period.custom(start_date: Date.current - 3.days, end_date: Date.current)
    other_account = create_account(balance: 1_000, accountable: Depository.new)
    deleted_account = create_account(balance: 20_000, accountable: Depository.new)
    create_balance(account: other_account, date: period.start_date, balance: 1_000)
    create_balance(account: other_account, date: period.end_date, balance: 1_000)
    create_balance(account: deleted_account, date: period.start_date, balance: 20_000)
    deleted_account.update_columns(status: "active", disabled_at: 10.days.ago)

    start_value = -> { BalanceSheet.new(@family).net_worth_series(period: period).values.index_by(&:date).fetch(period.start_date).value.amount }
    before = start_value.call
    assert_equal 21_000, before

    deleted_account.reload.mark_for_deletion!
    deleted_account.stubs(:cleanup_transfers).raises(StandardError, "destroy failed")
    assert_raises(StandardError) { deleted_account.destroy }
    assert deleted_account.reload.disabled?
    Rails.cache.clear

    assert_equal before, start_value.call
  end

  test "historical account scope respects shared-account finance settings" do
    member = users(:new_email)
    included_account = create_account(balance: 0, accountable: Depository.new)
    excluded_account = create_account(balance: 0, accountable: Depository.new)

    included_account.disable!
    excluded_account.disable!
    included_account.share_with!(member, include_in_finances: true)
    excluded_account.share_with!(member, include_in_finances: false)

    account_ids = BalanceSheet::HistoricalAccountScope.new(@family, user: member).account_ids

    assert_includes account_ids, included_account.id
    assert_not_includes account_ids, excluded_account.id
  end

  test "group totals skip shared accounts not included in the member's finances" do
    member = users(:new_email)
    included_account = create_account(balance: 1000, accountable: Depository.new)
    excluded_account = create_account(balance: 2000, accountable: Depository.new)
    included_account.share_with!(member, include_in_finances: true)
    excluded_account.share_with!(member, include_in_finances: false)

    assets = BalanceSheet.new(@family, user: member).assets
    depository_group = assets.account_groups.find { |ag| ag.name == Depository.display_name }

    assert_includes depository_group.accounts.map(&:id), excluded_account.id
    assert_equal 1000, depository_group.total
    assert_equal assets.total, assets.account_groups.sum(&:total)
  end

  test "calculates asset group totals" do
    create_account(balance: 1000, accountable: Depository.new)
    create_account(balance: 2000, accountable: Depository.new)
    create_account(balance: 3000, accountable: Investment.new)
    create_account(balance: 5000, accountable: OtherAsset.new)
    create_account(balance: 10000, accountable: CreditCard.new) # ignored

    asset_groups = BalanceSheet.new(@family).assets.account_groups

    assert_equal 3, asset_groups.size
    assert_equal 1000 + 2000, asset_groups.find { |ag| ag.name == Depository.display_name }.total
    assert_equal 3000, asset_groups.find { |ag| ag.name == Investment.display_name }.total
    assert_equal 5000, asset_groups.find { |ag| ag.name == OtherAsset.display_name }.total
  end

  test "calculates liability group totals" do
    create_account(balance: 1000, accountable: CreditCard.new)
    create_account(balance: 2000, accountable: CreditCard.new)
    create_account(balance: 3000, accountable: OtherLiability.new)
    create_account(balance: 5000, accountable: OtherLiability.new)
    create_account(balance: 10000, accountable: Depository.new) # ignored

    liability_groups = BalanceSheet.new(@family).liabilities.account_groups

    assert_equal 2, liability_groups.size
    assert_equal 1000 + 2000, liability_groups.find { |ag| ag.name == CreditCard.display_name }.total
    assert_equal 3000 + 5000, liability_groups.find { |ag| ag.name == OtherLiability.display_name }.total
  end

  test "sorts accounts in the user's manual order, new accounts last alphabetically" do
    user = users(:empty)
    user.update!(default_account_order: "manual")
    checking = create_account(name: "Checking", balance: 0, accountable: Depository.new, owner: user)
    savings = create_account(name: "Savings", balance: 0, accountable: Depository.new, owner: user)
    create_account(name: "Brokerage", balance: 0, accountable: Depository.new, owner: user)
    create_account(name: "Another", balance: 0, accountable: Depository.new, owner: user)
    card = create_account(name: "Card", balance: 0, accountable: CreditCard.new, owner: user)

    user.update_manual_account_order("depository", [ savings.id, checking.id ])
    user.update_manual_account_order("credit_card", [ card.id ])

    balance_sheet = BalanceSheet.new(@family, user: user)

    assert_equal %w[Savings Checking Another Brokerage], balance_sheet.assets.account_groups.first.accounts.map(&:name)
    assert_equal %w[Card], balance_sheet.liabilities.account_groups.first.accounts.map(&:name)
  end

  private
    def create_account(attributes = {})
      account = @family.accounts.create! name: "Test", currency: "USD", **attributes
      account
    end
end
