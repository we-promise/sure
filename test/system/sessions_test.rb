require "application_system_test_case"

class SessionsTest < ApplicationSystemTestCase
  setup do
    @user = users(:family_admin)
  end

  test "user can sign in with valid credentials" do
    visit new_session_path

    within %(form[action='#{sessions_path}']) do
      fill_in I18n.t("sessions.new.email"), with: @user.email
      fill_in I18n.t("sessions.new.password"), with: user_password_test
      click_on I18n.t("sessions.new.submit")
    end

    assert_selector "h1", text: "Welcome back, #{@user.first_name}"
  end

  test "user cannot sign in with invalid credentials" do
    visit new_session_path

    within %(form[action='#{sessions_path}']) do
      fill_in I18n.t("sessions.new.email"), with: @user.email
      fill_in I18n.t("sessions.new.password"), with: "wrong-password"
      click_on I18n.t("sessions.new.submit")
    end

    assert_text I18n.t("sessions.create.invalid_credentials")

    # The login form is re-rendered so the user can retry
    assert_selector %(form[action='#{sessions_path}'])
  end

  test "user can sign out and loses access to authenticated pages" do
    sign_in @user

    sign_out

    assert_text I18n.t("sessions.destroy.logout_successful")

    # A signed-out user is redirected back to the login page
    visit transactions_url
    assert_current_path new_session_path
  end
end
