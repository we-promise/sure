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

    within add_connection do
      click_on panel_t("qr_login")
    end
    within "#trade-republic-providers-panel" do
      assert_selector ".qrcode svg"
      assert_text panel_t("new_connection")
      assert_no_selector add_connection
    end
    assert_empty @user.family.trade_republic_items
    assert_equal 1, @user.family.trade_republic_pending_connections.count

    within "#trade-republic-providers-panel" do
      click_on panel_t("cancel_login")
      assert_selector add_connection
    end
    assert_empty @user.family.trade_republic_pending_connections
  end

  test "a PIN login opens a new connection's row and waits for approval there" do
    Provider::TradeRepublicClient.any_instance.stubs(:initiate_login).returns(
      Provider::TradeRepublicClient::Result.new(data: { "status" => "pending", "pending_login_b64" => "push-pending" })
    )
    Provider::TradeRepublicClient.any_instance.stubs(:login_stage).returns("authenticator_code")

    visit settings_providers_path
    find("a[href='#{connect_form_settings_providers_path(provider_key: "trade_republic")}']").click

    within add_connection do
      assert_no_field "trade_republic_pending_connection[pin]"
      click_on panel_t("pin_login")
      fill_in "trade_republic_pending_connection[phone_number]", with: "+491701234567"
      fill_in "trade_republic_pending_connection[pin]", with: "1234"
      click_on panel_t("connect")
    end

    within "#trade-republic-providers-panel" do
      assert_text panel_t("awaiting_authenticator_code")
      assert_no_selector add_connection
    end
    assert_empty @user.family.trade_republic_items
    assert_equal 1, @user.family.trade_republic_pending_connections.count
  end

  test "a QR login that fails can still be cancelled" do
    Provider::TradeRepublicClient.any_instance.stubs(:poll_qr_login).raises(Provider::TradeRepublicClient::Error, "boom")

    visit settings_providers_path
    find("a[href='#{connect_form_settings_providers_path(provider_key: "trade_republic")}']").click

    within(add_connection) { click_on panel_t("qr_login") }
    within "#trade-republic-providers-panel" do
      assert_text panel_t("qr_error")
      click_on panel_t("cancel_login")
      assert_selector add_connection
    end
    assert_empty @user.family.trade_republic_pending_connections
  end

  test "a lapsed QR login starts again from Add a connection with a single Cancel" do
    lapsed = @user.family.trade_republic_pending_connections.create!(qr_login: true)

    visit settings_providers_path
    find("a[href='#{connect_form_settings_providers_path(provider_key: "trade_republic")}']").click

    within "#trade-republic-providers-panel" do
      assert_text panel_t("login_expired")
      assert_button panel_t("qr_login"), count: 1
      within(add_connection) { click_on panel_t("qr_login") }
      assert_selector ".qrcode svg"
      assert_no_text panel_t("login_expired")
      assert_no_button panel_t("qr_cancel")
      assert_button panel_t("cancel_login"), count: 1
    end
    assert_not TradeRepublicPendingConnection.exists?(lapsed.id)
  end

  private

    def add_connection = "##{TradeRepublic::NewConnectionComponent::DOM_ID}"
    def panel_t(key) = I18n.t("settings.providers.trade_republic_panel.#{key}")
end
