require "application_system_test_case"

class TradeRepublicNewConnectionTest < ApplicationSystemTestCase
  setup do
    @user = users(:empty)
    sign_in @user

    pending = Provider::TradeRepublicClient::Result.new(data: {
      "status" => "pending",
      "pending_login_b64" => "pending",
      "qr_code_payload" => "https://example.com/qr"
    })
    Provider::TradeRepublicClient.any_instance.stubs(:initiate_qr_login).returns(pending)
    Provider::TradeRepublicClient.any_instance.stubs(:poll_qr_login).returns(pending)
    Provider::TradeRepublicClient.any_instance.stubs(:login_stage).returns("qr_pending")
  end

  test "a first connection logged in with QR exists only once Trade Republic approves it" do
    visit settings_providers_path
    find("a[href='#{connect_form_settings_providers_path(provider_key: "trade_republic")}']").click

    within "#trade-republic-providers-panel" do
      click_on panel_t("qr_login")
      assert_selector ".qrcode svg"
      assert_text panel_t("new_connection")
      assert_no_link panel_t("add_account")
    end
    assert_empty @user.family.trade_republic_items
    assert_equal 1, @user.family.trade_republic_pending_connections.count

    within "#trade-republic-providers-panel" do
      click_on panel_t("cancel_login")
      assert_field "trade_republic_pending_connection[phone_number]"
    end
    assert_empty @user.family.trade_republic_pending_connections
  end

  test "a QR login that fails can still be cancelled" do
    Provider::TradeRepublicClient.any_instance.stubs(:poll_qr_login).raises(Provider::TradeRepublicClient::Error, "boom")

    visit settings_providers_path
    find("a[href='#{connect_form_settings_providers_path(provider_key: "trade_republic")}']").click

    within "#trade-republic-providers-panel" do
      click_on panel_t("qr_login")
      assert_text panel_t("qr_error")
      click_on panel_t("cancel_login")
      assert_field "trade_republic_pending_connection[phone_number]"
    end
    assert_empty @user.family.trade_republic_pending_connections
  end

  test "a lapsed QR login starts again from its row with a single Cancel" do
    @user.family.trade_republic_pending_connections.create!(qr_login: true)

    visit settings_providers_path
    find("a[href='#{connect_form_settings_providers_path(provider_key: "trade_republic")}']").click

    within "#trade-republic-providers-panel" do
      assert_text panel_t("login_expired")
      click_on panel_t("qr_login")
      assert_selector ".qrcode svg"
      assert_no_button panel_t("qr_cancel")
      assert_button panel_t("cancel_login"), count: 1
    end
  end

  private

    def panel_t(key) = I18n.t("settings.providers.trade_republic_panel.#{key}")
end
