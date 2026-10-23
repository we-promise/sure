require "test_helper"

class AccountsHelperTest < ActionView::TestCase
  include AccountsHelper

  setup do
    @owner = users(:family_admin)
    @co_owner = users(:family_member)
    @account = accounts(:depository)
    Current.stubs(:user).returns(@owner)
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
    Current.stubs(:user).returns(@co_owner)

    assert_equal "40%", ownership_badge_label(@account.reload)
  end

  test "ownership badge keeps meaningful decimals and drops trailing zeros" do
    @account.update!(ownership_percentage: 33.33)

    assert_equal "33.33%", ownership_badge_label(@account)
  end

  test "ownership badge is hidden for a co-owner counting the whole account" do
    @account.update!(ownership_percentage: 60)
    Current.stubs(:user).returns(@co_owner)

    assert_nil ownership_badge_label(@account.reload)
  end
end
