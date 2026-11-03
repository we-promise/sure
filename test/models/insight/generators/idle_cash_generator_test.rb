require "test_helper"

class Insight::Generators::IdleCashGeneratorTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    # Both are untouched Depository accounts with 5,000 USD: `depository` is
    # shared with family_member, `connected` is private to family_admin.
    @shared = accounts(:depository)
    @private = accounts(:connected)
    Entry.where(account: [ @shared, @private ]).delete_all
  end

  test "nudges about an idle account every active member can see" do
    assert_includes nudged_account_ids, @shared.id
  end

  test "skips an account that is private to one member" do
    assert_not_includes nudged_account_ids, @private.id
  end

  test "an inactive member does not hide an account from the feed" do
    users(:family_member).update_columns(active: false)

    assert_includes nudged_account_ids, @private.id
  end

  test "formats balances with the family locale and ignores per-user overrides" do
    @family.update_columns(locale: "de", currency: "EUR")
    users(:family_admin).update_columns(amount_format: "indian")
    @shared.update_columns(currency: "EUR", balance: 5_000)
    @private.update_columns(currency: "EUR", balance: 5_000)

    insight = Insight::Generators::IdleCashGenerator.new(@family).generate.first

    assert_equal "5.000,00 €", insight.facts[:balance]
  end

  private
    def nudged_account_ids
      Insight::Generators::IdleCashGenerator.new(@family).generate.map { |insight| insight.metadata[:account_id] }
    end
end
