require "test_helper"

class FamilyMembershipTest < ActiveSupport::TestCase
  test "validates uniqueness of user and family pair" do
    user = users(:empty)
    family = families(:empty)

    FamilyMembership.create!(user: user, family: family)
    duplicate = FamilyMembership.new(user: user, family: family)

    assert_not duplicate.valid?
    assert_includes duplicate.errors[:user_id], "has already been taken"
  end
end
