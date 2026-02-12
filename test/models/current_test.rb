require "test_helper"

class CurrentTest < ActiveSupport::TestCase
  test "family returns session family when set" do
    user = users(:family_admin)
    family = families(:dylan_family)
    Current.session = user.sessions.create!(family: family)
    assert_equal family, Current.family
  end

  test "family falls back to user family when session has no family" do
    user = users(:family_admin)
    Current.session = user.sessions.create!
    assert_equal user.family, Current.family
  end

  test "membership returns the user membership for the current family" do
    user = users(:family_admin)
    family = families(:dylan_family)
    Current.session = user.sessions.create!(family: family)

    assert_not_nil Current.membership
    assert_equal family, Current.membership.family
    assert_equal user, Current.membership.user
  end

  test "admin? checks membership role for current family" do
    user = users(:family_admin)
    family = families(:dylan_family)
    Current.session = user.sessions.create!(family: family)

    assert Current.admin?
  end

  test "admin? returns true for super_admin regardless of membership" do
    user = users(:sure_support_staff)
    family = families(:empty)
    Current.session = user.sessions.create!(family: family)

    assert Current.admin?
  end

  test "admin? returns false for member role" do
    user = users(:family_member)
    family = families(:dylan_family)
    Current.session = user.sessions.create!(family: family)

    assert_not Current.admin?
  end
end
