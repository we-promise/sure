# frozen_string_literal: true

require "test_helper"

class FamilyPolicyTest < ActiveSupport::TestCase
  def setup
    @super_admin = users(:sure_support_staff)

    @regular_user = users(:family_member)
    @regular_user.update!(role: :member)

    @family = families(:empty)
  end

  test "super admin can destroy family" do
    assert FamilyPolicy.new(@super_admin, @family).destroy?
  end

  test "regular user cannot destroy family" do
    assert_not FamilyPolicy.new(@regular_user, @family).destroy?
  end

  test "nil user cannot destroy family" do
    assert_not FamilyPolicy.new(nil, @family).destroy?
  end
end
