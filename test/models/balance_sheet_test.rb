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

  private
    def create_account(attributes = {})
      account = @family.accounts.create! name: "Test", currency: "USD", **attributes
      account
    end
end
