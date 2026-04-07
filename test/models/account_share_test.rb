require "test_helper"

class AccountShareTest < ActiveSupport::TestCase
  setup do
    @admin = users(:family_admin)
    @member = users(:family_member)
    @account = accounts(:depository)
  end

  test "valid share" do
    # Use an account that doesn't already have a share with member
    account = accounts(:investment)
    account.account_shares.where(user: @member).destroy_all
    share = AccountShare.new(account: account, user: @member, permission: "read_only")
    assert share.valid?
  end

  test "invalid permission" do
    share = AccountShare.new(account: @account, user: @member, permission: "invalid")
    assert_not share.valid?
    assert_includes share.errors[:permission], "is not included in the list"
  end

  test "cannot share with account owner" do
    share = AccountShare.new(account: @account, user: @admin, permission: "read_only")
    assert_not share.valid?
    assert_includes share.errors[:user], "is already the owner of this account"
  end

  test "cannot duplicate share for same user and account" do
    # depository already shared with member via fixture
    duplicate = AccountShare.new(account: @account, user: @member, permission: "read_only")
    assert_not duplicate.valid?
  end

  test "permission helper methods" do
    share = AccountShare.new(permission: "full_control")
    assert share.full_control?
    assert_not share.read_write?
    assert_not share.read_only?
    assert share.can_annotate?
    assert share.can_edit?

    share.permission = "read_write"
    assert share.read_write?
    assert share.can_annotate?
    assert_not share.can_edit?

    share.permission = "read_only"
    assert share.read_only?
    assert_not share.can_annotate?
    assert_not share.can_edit?
  end

  test "cannot share with user from different family" do
    other_user = users(:empty)
    share = AccountShare.new(account: @account, user: other_user, permission: "read_only")
    assert_not share.valid?
    assert_includes share.errors[:user], "must be in the same family"
  end
end
