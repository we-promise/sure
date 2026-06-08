require "test_helper"

class CurrentTest < ActiveSupport::TestCase
  test "family returns user family" do
    user = users(:family_admin)
    Current.session = user.sessions.create!
    assert_equal user.family, Current.family
  end

  test "family returns active family from session when user has access" do
    user = users(:family_admin)
    additional_family = Family.create!(name: "Business")
    FamilyMembership.create!(user: user, family: additional_family)

    Current.session = user.sessions.create!
    Current.session.set_active_family_id(additional_family.id)

    assert_equal additional_family, Current.family
  end

  test "family falls back to primary family when session family is not accessible" do
    user = users(:family_admin)
    inaccessible_family = Family.create!(name: "Client")

    Current.session = user.sessions.create!
    Current.session.set_active_family_id(inaccessible_family.id)

    assert_equal user.family, Current.family
  end
end
