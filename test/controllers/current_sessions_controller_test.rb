require "test_helper"

class CurrentSessionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    sign_in @user
  end

  test "can update the preferred tab for any namespace" do
    put current_session_url,
        params: { current_session: { tab_key: "accounts_sidebar_tab", tab_value: "asset" } },
        as: :json

    assert_response :success
    session = @user.sessions.order(updated_at: :desc).first
    assert_equal "asset", session.get_preferred_tab("accounts_sidebar_tab")
  end

  test "can update the active family when user has membership" do
    additional_family = Family.create!(name: "Business")
    FamilyMembership.create!(user: @user, family: additional_family)

    put current_session_url,
        params: { current_session: { active_family_id: additional_family.id } },
        as: :json

    assert_response :success
    session = @user.sessions.order(updated_at: :desc).first
    assert_equal additional_family.id, session.get_active_family_id
  end

  test "ignores active family updates outside user memberships" do
    put current_session_url,
        params: { current_session: { active_family_id: families(:empty).id } },
        as: :json

    assert_response :success
    session = @user.sessions.order(updated_at: :desc).first
    assert_nil session.get_active_family_id
  end
end
