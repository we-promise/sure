require "test_helper"

class AccountsHelperTest < ActionView::TestCase
  setup do
    @user = users(:family_admin)
    @co_owner = users(:family_member)
    @account = accounts(:depository)
    Current.session = @user.sessions.create!
  end

  teardown { Current.session = nil }

  test "sidebar cache key changes with the account order" do
    @user.update!(default_account_order: "name_asc")
    name_key = sidebar_key

    @user.update!(default_account_order: "balance_desc")

    assert_not_equal name_key, sidebar_key
  end

  test "sidebar cache key changes when the manual order changes" do
    @user.update!(default_account_order: "manual")
    before = sidebar_key

    @user.update_manual_account_order("depository", [ accounts(:connected).id, accounts(:depository).id ])

    assert_not_equal before, sidebar_key
  end

  test "ownership badge is hidden for a fully owned account" do
    assert_nil ownership_badge_label(@account)
  end

  test "ownership badge shows the owner's percentage" do
    @account.update!(ownership_percentage: 60)

    assert_equal "60%", ownership_badge_label(@account)
  end

  test "ownership badge shows a co-owner's own percentage, not the owner's" do
    @account.update!(ownership_percentage: 60)
    @account.account_shares.find_by!(user: @co_owner).update!(ownership_percentage: 40)
    Current.session = @co_owner.sessions.create!

    assert_equal "40%", ownership_badge_label(@account.reload)
  end

  test "ownership badge keeps meaningful decimals and drops trailing zeros" do
    @account.update!(ownership_percentage: 33.33)

    assert_equal "33.33%", ownership_badge_label(@account)
  end

  test "ownership badge is hidden for a co-owner counting the whole account" do
    @account.update!(ownership_percentage: 60)
    Current.session = @co_owner.sessions.create!

    assert_nil ownership_badge_label(@account.reload)
  end

  private
    def sidebar_key
      account_sidebar_tabs_cache_key(family: @user.family, active_tab: "all", mobile: false)
    end
end
