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

  test "splits an account group into subgroups whose totals add up" do
    create_account(balance: 1000, accountable: Depository.new, institution_name: "ING")
    create_account(balance: 2000, accountable: Depository.new, institution_name: " ing ")
    create_account(balance: 4000, accountable: Depository.new, institution_name: "Sparkasse")
    create_account(balance: 8000, accountable: Depository.new)
    create_account(balance: 15000, accountable: OtherAsset.new)

    group = BalanceSheet.new(@family).assets.account_groups.find { |ag| ag.key == "depository" }
    subgroups = group.subgroups("institution", user: users(:empty))

    assert_equal [ "ING", "Sparkasse", I18n.t("account_grouping.none") ], subgroups.map(&:name)
    assert_equal [ 3000, 4000, 8000 ], subgroups.map(&:total)
    assert_equal group.total, subgroups.sum(&:total)
    assert_in_delta group.weight, subgroups.sum(&:weight), 0.001
  end

  test "offsetting subgroups keep their share of the classification" do
    create_account(balance: 1000, accountable: Depository.new, custom_group: "A")
    create_account(balance: -1000, accountable: Depository.new, custom_group: "B")
    create_account(balance: 10000, accountable: OtherAsset.new)

    group = BalanceSheet.new(@family).assets.account_groups.find { |ag| ag.key == "depository" }
    subgroups = group.subgroups("custom_group", user: users(:empty))

    assert_equal [ 10, -10 ], subgroups.map { |subgroup| subgroup.weight.round }
  end

  test "a group whose accounts share one value still shows its one subgroup" do
    create_account(balance: 1000, accountable: Depository.new, custom_group: "Kids")
    create_account(balance: 2000, accountable: Depository.new, custom_group: "kids")
    create_account(balance: 500, accountable: CreditCard.new)

    balance_sheet = BalanceSheet.new(@family)
    group = balance_sheet.assets.account_groups.first
    credit_cards = balance_sheet.liabilities.account_groups.first

    assert_equal [ "Kids" ], group.subgroups("custom_group", user: users(:empty)).map(&:name)
    assert_equal [ I18n.t("account_grouping.none") ], credit_cards.subgroups("custom_group", user: users(:empty)).map(&:name)
    assert_equal [ 500 ], credit_cards.subgroups("custom_group", user: users(:empty)).map(&:total)
    assert_empty group.subgroups("unknown", user: users(:empty))
  end

  test "groups accounts by another first level across account types" do
    create_account(balance: 1000, accountable: Depository.new, institution_name: "ING")
    create_account(balance: 2000, accountable: Investment.new, institution_name: "ing")
    create_account(balance: 4000, accountable: Depository.new, institution_name: "Sparkasse")
    create_account(balance: 8000, accountable: OtherAsset.new)
    create_account(balance: 500, accountable: CreditCard.new, institution_name: "ING")

    balance_sheet = BalanceSheet.new(@family)
    groups = balance_sheet.assets.account_groups(by: "institution", user: users(:empty))

    assert_equal [ "ING", "Sparkasse", I18n.t("account_grouping.none") ], groups.map(&:name)
    assert_equal [ 3000, 4000, 8000 ], groups.map(&:total)
    assert_equal balance_sheet.assets.total, groups.sum(&:total)
    assert_in_delta 100, groups.sum(&:weight), 0.001
    assert groups.none?(&:type_group?)
    assert groups.all? { |group| group.color.present? }

    liability_groups = balance_sheet.liabilities.account_groups(by: "institution", user: users(:empty))
    assert_equal [ "ING" ], liability_groups.map(&:name)
    assert_equal 500, liability_groups.first.total

    all_keys = balance_sheet.account_groups(by: "institution", user: users(:empty)).map(&:key)
    assert_equal all_keys.uniq, all_keys, "an asset and a debt group with the same value need distinct keys"
  end

  test "splits a first level by account type as second level" do
    create_account(balance: 1000, accountable: Depository.new, custom_group: "Household")
    create_account(balance: 2000, accountable: Investment.new, custom_group: "Household")

    group = BalanceSheet.new(@family).assets.account_groups(by: "custom_group", user: users(:empty)).first
    subgroups = group.subgroups("account_type", user: users(:empty))

    assert_equal "Household", group.name
    assert_equal [ Depository.display_name, Investment.display_name ], subgroups.map(&:name)
    assert_equal [ 1000, 2000 ], subgroups.map(&:total)
  end

  test "groups by ownership for the balance sheet's own viewer by default" do
    viewer = users(:empty)
    create_account(balance: 1000, accountable: Depository.new, owner: viewer)

    groups = BalanceSheet.new(@family, user: viewer).account_groups(by: "ownership")

    assert_equal [ I18n.t("account_grouping.ownership.mine") ], groups.map(&:name)
  end

  test "account type as first level keeps the default type groups" do
    create_account(balance: 1000, accountable: Depository.new)

    default_keys = BalanceSheet.new(@family).assets.account_groups.map(&:key)
    by_type_keys = BalanceSheet.new(@family).assets.account_groups(by: "account_type", user: users(:empty)).map(&:key)

    assert_equal default_keys, by_type_keys
    assert BalanceSheet.new(@family).assets.account_groups.all?(&:type_group?)
  end

  private
    def create_account(attributes = {})
      account = @family.accounts.create! name: "Test", currency: "USD", **attributes
      account
    end
end
