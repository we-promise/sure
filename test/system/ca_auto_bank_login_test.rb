require "application_system_test_case"
require Rails.root.join("test/support/ca_auto_bank_test_helper")

class CaAutoBankLoginTest < ApplicationSystemTestCase
  include CaAutoBankTestHelper

  setup do
    @user = users(:family_admin)
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
    ActiveRecordEncryptionConfig.stubs(:explicitly_configured?).returns(true)
    CaAutoBankItem.any_instance.stubs(:sync_later)
    CaAutoBankItem.any_instance.stubs(:syncing?).returns(false)
    auth_root = "#{Provider::CaAutoBank::ORIGIN}#{Provider::CaAutoBank::AUTH_ROOT}"
    stub_request(:post, "#{auth_root}/login").to_return(status: 511,
      body: { errorCode: 5110000, appAuthorizationRequired: true, verificationToken: "private-bank-approval" }.to_json)
    @poll_request = stub_request(:post, "#{auth_root}/login/tfa").to_return(status: 511,
      body: { errorCode: 5110003, appAuthorizationRequired: true }.to_json)
      .then.to_return(status: 200, body: { authenticationToken: ca_token }.to_json)
    stub_request(:get, "#{auth_root}/user").to_return(status: 200, body: { partnerId: "synthetic-partner" }.to_json)
  end

  teardown { Current.reset }

  test "phone approval completes from Sure automatically and saved deposits stay visible on mobile" do
    with_self_hosting do
      sign_in @user
      visit ca_auto_bank_login_path
      find("input[type=email]").set("owner@example.com")
      find("input[type=password]").set("synthetic-password")
      click_button I18n.t("ca_auto_bank.connect")
      assert_text I18n.t("ca_auto_bank.approval_title")
      assert_no_text "private-bank-approval"
      assert_no_text "synthetic-password"
      assert_no_button I18n.t("ca_auto_bank.check_approval")
      assert_current_path accounts_path, wait: 30
      assert_requested @poll_request, times: 2

      item = CaAutoBankItem.find_by!(owner: @user)
      CaAutoBankItem::Importer.new(item).import(snapshot: ca_snapshot(item))
      visit accounts_path
      assert_text "CA Auto Bank Libero"
      assert_text "CA Auto Bank Tempo"
      deposit = item.ca_auto_bank_accounts.find_by!(kind: "time_deposit")
      visit account_path(deposit.account)
      assert_text I18n.t("ca_auto_bank.deposit_details")
      assert_text I18n.t("ca_auto_bank.principal_note")
      assert_text "3.50%"
      page.current_window.resize_to(390, 844)
      assert_text I18n.t("ca_auto_bank.history_note")
      assert_selector "section[aria-label='#{I18n.t('ca_auto_bank.deposit_details')}']"
    end
  end
end
