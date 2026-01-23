# frozen_string_literal: true

require "test_helper"

class UserPolicyTest < ActiveSupport::TestCase
  def setup
    @super_admin = users(:family_admin)
    @super_admin.update!(role: :super_admin)

    @regular_user = users(:family_member)
    @regular_user.update!(role: :member)

    @other_user = users(:sure_support_staff)
    @other_user.update!(role: :member)
  end

  test "super admin can view index" do
    assert UserPolicy.new(@super_admin, User).index?
  end

  test "regular user cannot view index" do
    assert_not UserPolicy.new(@regular_user, User).index?
  end

  test "nil user cannot view index" do
    assert_not UserPolicy.new(nil, User).index?
  end

  test "super admin can update another user" do
    assert UserPolicy.new(@super_admin, @regular_user).update?
  end

  test "super admin cannot update themselves" do
    assert_not UserPolicy.new(@super_admin, @super_admin).update?
  end

  test "regular user cannot update anyone" do
    assert_not UserPolicy.new(@regular_user, @other_user).update?
  end

  test "nil user cannot update anyone" do
    assert_not UserPolicy.new(nil, @regular_user).update?
  end

  test "scope returns all users for super admin" do
    scope = UserPolicy::Scope.new(@super_admin, User).resolve
    assert_equal User.count, scope.count
  end

  test "scope returns no users for regular user" do
    scope = UserPolicy::Scope.new(@regular_user, User).resolve
    assert_equal 0, scope.count
  end

  test "scope returns no users for nil user" do
    scope = UserPolicy::Scope.new(nil, User).resolve
    assert_equal 0, scope.count
  end
end
