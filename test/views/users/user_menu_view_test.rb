require "test_helper"

class UserMenuViewTest < ActionView::TestCase
  test "ledger switch posts active family under current_session scope" do
    user = users(:family_admin)
    Current.session = user.sessions.create!
    additional_family = Family.create!(name: "Business")
    FamilyMembership.create!(user: user, family: additional_family)
    stubs(:self_hosted?).returns(false)

    html = render(partial: "users/user_menu", locals: { user: user })

    assert_includes html, 'name="current_session[active_family_id]"'
    assert_not_includes html, 'name="active_family_id"'
  end
end
