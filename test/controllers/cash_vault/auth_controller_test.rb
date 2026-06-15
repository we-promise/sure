require "test_helper"

module CashVault
  class AuthControllerTest < ActionDispatch::IntegrationTest
    setup do
      @owner = User.create!(
        family: families(:dylan_family),
        first_name: "F0-SU-1",
        email: "adminF0@bookeepz.net",
        password: user_password_test,
        password_confirmation: user_password_test,
        role: :super_admin,
        onboarded_at: Time.current,
        ui_layout: :dashboard
      )
    end

    test "family admin cannot access auth page" do
      sign_in users(:family_admin)

      get cash_vault_auth_path

      assert_redirected_to root_path
    end

    test "non bootstrap super admin cannot access auth page" do
      sign_in users(:sure_support_staff)

      get cash_vault_auth_path

      assert_redirected_to root_path
    end

    test "bootstrap platform owner can access auth page" do
      sign_in @owner

      get cash_vault_auth_path

      assert_response :ok
      assert_select "form[action='#{cash_vault_auth_path}'][method='post']"
      assert_select "input[type='password'][name='password']"
    end

    test "auth page does not render super admin controls" do
      sign_in @owner

      get cash_vault_auth_path

      assert_response :ok
      refute_includes @response.body, "SUPER ADMIN"
      refute_includes @response.body, "Company"
      refute_includes @response.body, "Switch"
    end

    test "wrong password rerenders auth page" do
      sign_in @owner

      post cash_vault_auth_path, params: { password: "not-the-password" }

      assert_response :unprocessable_entity
      assert_includes @response.body, "Invalid password"
    end

    test "correct password unlocks table once" do
      sign_in @owner

      post cash_vault_auth_path, params: { password: user_password_test }

      assert_redirected_to cash_vault_transactions_path
    end
  end
end
