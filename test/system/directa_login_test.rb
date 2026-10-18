require "application_system_test_case"

class DirectaLoginTest < ApplicationSystemTestCase
  setup do
    @user = users(:family_admin)
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
    ActiveRecordEncryptionConfig.stubs(:explicitly_configured?).returns(true)

    challenge = Provider::Directa::LoginChallenge.new(
      account_number: "00123",
      challenge_token: "synthetic-directa-challenge",
      connection_generation: 1
    )
    verified_session = Provider::Directa::VerifiedSession.new(
      account_number: "00123",
      account_identity: "synthetic-verified-account",
      multi_token: "synthetic-multi-token",
      mono_token: "synthetic-mono-token",
      host: Provider::Directa::HOST,
      connection_generation: 1
    )
    client = mock("Directa login client")
    client.expects(:begin_login).with(
      account_number: "00123",
      password: "synthetic-directa-password",
      connection_generation: 1
    ).returns(challenge)
    client.expects(:complete_login).with(
      account_number: "00123",
      challenge_token: "synthetic-directa-challenge",
      otp_code: "123456",
      connection_generation: 1
    ).returns(verified_session)
    Provider::Directa.expects(:new).twice.returns(client)
    DirectaItem.any_instance.stubs(:syncing?).returns(false)
    DirectaItem.any_instance.expects(:sync_later).once
  end

  teardown do
    Current.reset
  end

  test "Add Investment opens Directa and the Turbo login flow redirects through OTP to authentication" do
    provider_link = I18n.t("accounts.new.method_selector.link_with_provider", provider: "Directa")

    with_self_hosting do
      sign_in @user
      visit accounts_path
      click_link "New account"
      click_link Accountable.from_type("Investment").singular_display_name
      click_link provider_link

      assert_current_path directa_login_path
      assert_text I18n.t("directa_logins.show.title")
      find("#broker_account").set("123")
      find("#current-password").set("synthetic-directa-password")
      click_button I18n.t("directa_logins.show.connect")

      assert_current_path directa_login_path
      assert_text I18n.t("directa_logins.show.otp_requested")
      assert_selector "#directa-otp-code[autocomplete='one-time-code']"
      find("#directa-otp-code").set("123456")
      click_button I18n.t("directa_logins.show.verify_otp")

      assert_current_path directa_login_path
      assert_text I18n.t("directa_logins.show.authenticated_waiting_for_sync")
      assert_text I18n.t("directa_logins.show.status_waiting_for_snapshot")
      assert_no_text "synthetic-directa-challenge"
      assert_no_text "synthetic-multi-token"
      assert_no_text "synthetic-mono-token"
      assert_no_text "synthetic-directa-password"

      visit connect_form_settings_providers_path(provider_key: "directa")
      assert_selector "turbo-frame#directa-connect-form[target='_top'] a[href='#{directa_login_path}'][data-turbo-frame='_top']"
    end
  end
end
