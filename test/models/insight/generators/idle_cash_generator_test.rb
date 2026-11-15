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

  private
    def nudged_account_ids
      Insight::Generators::IdleCashGenerator.new(@family).generate.map { |insight| insight.metadata[:account_id] }
    end
end
