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
end
