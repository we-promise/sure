require "test_helper"

class Settings::AppearancesControllerTest < ActionDispatch::IntegrationTest
  test "admin can enable auto-generate transaction names for the whole family" do
    sign_in users(:family_admin)
    families(:dylan_family).update!(auto_generate_transaction_names: false)

    patch settings_appearance_path, params: { family: { auto_generate_transaction_names: "1" } }

    assert_redirected_to settings_appearance_path
    assert families(:dylan_family).reload.auto_generate_transaction_names?
  end

  test "admin can disable auto-generate transaction names for the whole family" do
    sign_in users(:family_admin)
    families(:dylan_family).update!(auto_generate_transaction_names: true)

    patch settings_appearance_path, params: { family: { auto_generate_transaction_names: "0" } }

    assert_redirected_to settings_appearance_path
    assert_not families(:dylan_family).reload.auto_generate_transaction_names?
  end

  test "non-admin family member cannot change the family-wide setting" do
    sign_in users(:family_member)
    families(:dylan_family).update!(auto_generate_transaction_names: false)

    patch settings_appearance_path, params: { family: { auto_generate_transaction_names: "1" } }

    assert_redirected_to settings_appearance_path
    assert_not families(:dylan_family).reload.auto_generate_transaction_names?
  end

  test "show renders successfully" do
    sign_in @user = users(:family_admin)
    get settings_appearance_path
    assert_response :success
  end

  test "update persists show_counterparty_account preference" do
    sign_in @user = users(:family_admin)
    patch settings_appearance_path, params: { user: { show_counterparty_account: "0" } }
    assert_redirected_to settings_appearance_path
    assert_equal false, @user.reload.show_counterparty_account?

    patch settings_appearance_path, params: { user: { show_counterparty_account: "1" } }
    assert @user.reload.show_counterparty_account?
  end

  test "update does not touch show_counterparty_account when the param is absent" do
    sign_in @user = users(:family_admin)
    @user.update!(preferences: { "show_counterparty_account" => false })

    patch settings_appearance_path, params: { user: { show_split_grouped: "1" } }

    assert_not @user.reload.show_counterparty_account?
  end
end
