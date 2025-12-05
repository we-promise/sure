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

  test "cash subgroups render savings and uncategorized when enabled" do
    create_account(balance: 100, accountable: Depository.new(subtype: "savings"))
    create_account(balance: 200, accountable: Depository.new) # no subtype

    cash_group = BalanceSheet.new(@family).assets.account_groups.find { |ag| ag.name == "Cash" }

    assert_equal ["Savings"], cash_group.subgroups.map(&:name)
    assert_equal 1, cash_group.uncategorized_accounts.size
    assert_equal 20000.0, cash_group.uncategorized_total_money.to_f
  end

  test "cash subgroups flatten when preference disabled" do
    @family.update!(cash_subgroup_enabled: false)

    create_account(balance: 100, accountable: Depository.new(subtype: "savings"))
    create_account(balance: 200, accountable: Depository.new)

    cash_group = BalanceSheet.new(@family).assets.account_groups.find { |ag| ag.name == "Cash" }

    assert_empty cash_group.subgroups
    assert_empty cash_group.uncategorized_accounts
    assert_equal 2, cash_group.accounts.size
  end

  test "unknown cash subtypes are treated as uncategorized" do
    create_account(balance: 150, accountable: Depository.new(subtype: "mystery"))

    cash_group = BalanceSheet.new(@family).assets.account_groups.find { |ag| ag.name == "Cash" }

    assert_empty cash_group.subgroups
    assert_equal 1, cash_group.uncategorized_accounts.size
    assert_equal 15000.0, cash_group.uncategorized_total_money.to_f
  end

  private
    def create_account(attributes = {})
      account = @family.accounts.create! name: "Test", currency: "USD", **attributes
      account
    end
end
