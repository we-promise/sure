require "test_helper"

class TradeRepublicPanelRenderTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
  end

  test "an expired login request offers to log in again" do
    trade_republic_items(:configured_item).update!(pending_login_state: "some-state")
    TradeRepublicItem.any_instance.stubs(:login_stage).returns("expired")

    get connect_form_settings_providers_path(provider_key: "trade_republic")
    assert_response :success

    assert_includes response.body, I18n.t("settings.providers.trade_republic_panel.login_expired")
    assert_includes response.body, I18n.t("settings.providers.trade_republic_panel.qr_login")
    assert_includes response.body, I18n.t("settings.providers.trade_republic_panel.pin_login")
  end

  test "item stuck in a pending login state still renders remove" do
    item = trade_republic_items(:configured_item)
    item.update!(pending_login_state: "some-state")

    get connect_form_settings_providers_path(provider_key: "trade_republic")
    assert_response :success

    assert_includes response.body, I18n.t("settings.providers.trade_republic_panel.remove")
    assert_includes response.body, trade_republic_item_path(item)
  end

  test "item without a configured session still renders remove" do
    item = trade_republic_items(:no_session_item)

    get connect_form_settings_providers_path(provider_key: "trade_republic")
    assert_response :success

    assert_includes response.body, I18n.t("settings.providers.trade_republic_panel.remove")
    assert_includes response.body, trade_republic_item_path(item)
  end

  test "new record form renders QR submit via DS::Button" do
    sign_in users(:empty)

    get connect_form_settings_providers_path(provider_key: "trade_republic")
    assert_response :success

    assert_includes response.body, 'name="login_method"'
    assert_includes response.body, 'value="qr"'
    refute_includes response.body, "hover:bg-primary/10"
  end

  test "multiple connections render as separate cards with independent action URLs" do
    first_item = trade_republic_items(:configured_item)
    second_item = trade_republic_items(:requires_update_item)

    get connect_form_settings_providers_path(provider_key: "trade_republic")
    assert_response :success

    assert_includes response.body, first_item.name
    assert_includes response.body, second_item.name
    assert_includes response.body, sync_trade_republic_item_path(first_item)
    assert_includes response.body, trade_republic_item_path(second_item)
  end
end
