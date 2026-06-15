require "test_helper"

module CashVault
  class TransactionsControllerTest < ActionDispatch::IntegrationTest
    include EntriesTestHelper

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

    test "table requires one time password unlock" do
      sign_in @owner

      get cash_vault_transactions_path
      assert_redirected_to cash_vault_auth_path

      post cash_vault_auth_path, params: { password: user_password_test }
      follow_redirect!
      assert_response :ok

      get cash_vault_transactions_path
      assert_redirected_to cash_vault_auth_path
    end

    test "failed auth clears any pending one time unlock" do
      sign_in @owner

      post cash_vault_auth_path, params: { password: user_password_test }
      assert_redirected_to cash_vault_transactions_path

      post cash_vault_auth_path, params: { password: "not-the-password" }
      assert_response :unprocessable_entity

      get cash_vault_transactions_path
      assert_redirected_to cash_vault_auth_path
    end

    test "table is unavailable to non bootstrap super admin" do
      sign_in users(:sure_support_staff)

      get cash_vault_transactions_path

      assert_redirected_to root_path
    end

    test "table includes only current workspace depository transactions" do
      sign_in @owner

      included = create_transaction(account: accounts(:depository), name: "Cash vault included", amount: 42)
      create_transaction(account: accounts(:credit_card), name: "Cash vault credit card", amount: 43)
      create_transaction(account: accounts(:investment), name: "Cash vault investment", amount: 44)
      create_transaction(account: accounts(:loan), name: "Cash vault loan", amount: 45)

      other_account = families(:empty).accounts.create!(
        name: "Other family cash",
        balance: 0,
        currency: "USD",
        accountable: Depository.new
      )
      create_transaction(account: other_account, name: "Cash vault other family", amount: 46)

      post cash_vault_auth_path, params: { password: user_password_test }
      follow_redirect!

      assert_response :ok
      assert_includes @response.body, included.name
      refute_includes @response.body, "Cash vault credit card"
      refute_includes @response.body, "Cash vault investment"
      refute_includes @response.body, "Cash vault loan"
      refute_includes @response.body, "Cash vault other family"
    end

    test "table does not render super admin controls" do
      sign_in @owner

      post cash_vault_auth_path, params: { password: user_password_test }
      follow_redirect!

      assert_response :ok
      refute_includes @response.body, "SUPER ADMIN"
      refute_includes @response.body, "Company"
      refute_includes @response.body, "Switch"
    end
  end
end
