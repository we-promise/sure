require "test_helper"

class TradeRepublicPanelRenderTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
  end

  test "expired login state renders restart login via DS::Button" do
    TradeRepublicItem.any_instance.stubs(:login_stage).returns("expired")
    TradeRepublicItem.any_instance.stubs(:pending_login_state).returns("some-state")

    get connect_form_settings_providers_path(provider_key: "trade_republic")
    assert_response :success

    assert_includes response.body, I18n.t("settings.providers.trade_republic_panel.restart_login")
    assert_includes response.body, '<form class="ml-auto'
    refute_includes response.body, "hover:border-primary"
  end

  test "new record form renders QR submit via DS::Button" do
    sign_in users(:empty)

    get connect_form_settings_providers_path(provider_key: "trade_republic")
    assert_response :success

    assert_includes response.body, 'name="login_method"'
    assert_includes response.body, 'value="qr"'
    refute_includes response.body, "hover:bg-primary/10"
  end

  test "configured connection renders an accessible disconnect button" do
    TradeRepublicItem.any_instance.stubs(:session_configured?).returns(true)

    get connect_form_settings_providers_path(provider_key: "trade_republic")
    assert_response :success

    disconnect_label = I18n.t("settings.providers.trade_republic_panel.disconnect")
    assert_includes response.body, %(aria-label="#{disconnect_label}")
    assert_includes response.body, %(title="#{disconnect_label}")
  end
end
