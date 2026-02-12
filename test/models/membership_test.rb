require "test_helper"

class MembershipTest < ActiveSupport::TestCase
  setup do
    @membership = memberships(:dylan_admin)
    @user = users(:family_admin)
    @family = families(:dylan_family)
  end

  test "belongs to user and family" do
    assert_equal @user, @membership.user
    assert_equal @family, @membership.family
  end

  test "enforces uniqueness of user per family" do
    duplicate = Membership.new(user: @user, family: @family, role: "member")
    assert_not duplicate.valid?
  end

  test "admin? returns true for admin role" do
    assert @membership.admin?
  end

  test "admin? returns true for super_admin user even with non-admin membership role" do
    super_admin = users(:sure_support_staff)
    membership = memberships(:sure_support_admin)
    assert membership.admin?
  end

  test "admin? returns false for member role" do
    member_membership = memberships(:dylan_member)
    assert_not member_membership.admin?
  end

  test "validates role inclusion" do
    @membership.role = "invalid"
    assert_not @membership.valid?
  end
end
