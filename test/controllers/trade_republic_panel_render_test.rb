require "test_helper"

class TradeRepublicPanelRenderTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
  end

  test "expired login state renders restart login via DS::Button" do
    trade_republic_items(:configured_item).update!(pending_login_state: "some-state")
    TradeRepublicItem.any_instance.stubs(:login_stage).returns("expired")

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
    item = trade_republic_items(:configured_item)

    get connect_form_settings_providers_path(provider_key: "trade_republic")
    assert_response :success

    disconnect_label = I18n.t("settings.providers.trade_republic_panel.disconnect")
    assert_includes response.body, %(aria-label="#{disconnect_label}")
    assert_includes response.body, %(title="#{disconnect_label}")
    assert_includes response.body, trade_republic_item_path(item)
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
