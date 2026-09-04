require "test_helper"

class TradeRepublicItemsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
  end

  test "create rejects a web login without a PIN before persisting the item" do
    assert_no_difference "TradeRepublicItem.count" do
      post trade_republic_items_url, params: {
        trade_republic_item: {
          phone_number: "+491701234567",
          pin: ""
        }
      }
    end

    assert_redirected_to settings_providers_path(anchor: "trade-republic")
    assert_equal I18n.t("trade_republic_items.initiate_login.pin_required"), flash[:alert]
  end

  test "update rejects a changed phone number without a PIN" do
    item = trade_republic_items(:configured_item)
    original_phone_number = item.phone_number
    original_session_blob = item.session_blob

    patch trade_republic_item_url(item), params: {
      trade_republic_item: {
        phone_number: "+491709999999",
        pin: ""
      }
    }

    assert_redirected_to settings_providers_path(anchor: "trade-republic")
    assert_equal I18n.t("trade_republic_items.update.pin_required"), flash[:alert]
    item.reload
    assert_equal original_phone_number, item.phone_number
    assert_equal original_session_blob, item.session_blob
  end

  test "initiate login does not destroy a working session when the PIN is missing" do
    item = trade_republic_items(:configured_item)
    original_session_blob = item.session_blob

    post initiate_login_trade_republic_item_url(item)

    assert_redirected_to settings_providers_path(anchor: "trade-republic")
    assert_equal I18n.t("trade_republic_items.initiate_login.pin_required"), flash[:alert]
    item.reload
    assert_equal original_session_blob, item.session_blob
    assert_predicate item, :good?
  end

  test "initiate login clears an expired pending state when the PIN is missing" do
    item = trade_republic_items(:requires_update_item)
    item.update!(pending_login_state: "expired-state")

    post initiate_login_trade_republic_item_url(item)

    assert_redirected_to settings_providers_path(anchor: "trade-republic")
    assert_equal I18n.t("trade_republic_items.initiate_login.pin_required"), flash[:alert]
    item.reload
    assert_nil item.pending_login_state
    assert_predicate item, :requires_update?
  end

  test "complete account setup creates and links the selected account" do
    item = trade_republic_items(:configured_item)
    provider_account = trade_republic_accounts(:main_account)

    assert_difference "Account.count", 1 do
      assert_difference "AccountProvider.count", 1 do
        post complete_account_setup_trade_republic_item_url(item), params: {
          account_ids: [ provider_account.id ]
        }
      end
    end

    assert_redirected_to accounts_path
    provider_account.reload
    assert_not_nil provider_account.current_account
  end

  test "complete account setup rolls back an account when linking fails" do
    item = trade_republic_items(:configured_item)
    provider_account = trade_republic_accounts(:main_account)
    TradeRepublicAccount.any_instance.stubs(:ensure_account_provider!).returns(nil)

    assert_no_difference "Account.count" do
      assert_no_difference "AccountProvider.count" do
        post complete_account_setup_trade_republic_item_url(item), params: {
          account_ids: [ provider_account.id ]
        }
      end
    end

    assert_redirected_to setup_accounts_trade_republic_item_path(item)
    assert_equal I18n.t("trade_republic_items.complete_account_setup.partial_failure", count: 1), flash[:alert]
  end

  test "link_existing_account rejects an account already connected to another provider" do
    item = trade_republic_items(:no_session_item)
    trade_republic_account = trade_republic_accounts(:pending_setup_account)
    account = accounts(:connected)
    account.reload
    assert_not_nil account.plaid_account_id

    assert_no_difference "AccountProvider.count" do
      post link_existing_account_trade_republic_items_url, params: {
        account_id: account.id,
        trade_republic_account_id: trade_republic_account.id
      }
    end

    assert_redirected_to account_path(account)
    assert_equal I18n.t("trade_republic_items.link_existing_account.only_manual_investment"), flash[:alert]
    trade_republic_account.reload
    assert_nil trade_republic_account.current_account
    assert_equal item, trade_republic_account.trade_republic_item
  end

  test "successful QR polling can complete without a phone number" do
    item = families(:dylan_family).trade_republic_items.create!(
      name: "Trade Republic QR Connection",
      currency: "EUR",
      status: :requires_update
    )
    item.update!(pending_login_state: "qr-pending")
    provider = mock
    provider.expects(:poll_qr_login).with(pending_login_b64: "qr-pending").returns(
      Provider::TradeRepublicClient::Result.new(
        data: { "status" => "confirmed", "session_txt" => "qr-session" }
      )
    )
    TradeRepublicItem.any_instance.stubs(:trade_republic_provider).returns(provider)
    TradeRepublicItem.any_instance.stubs(:syncing?).returns(true)

    post poll_qr_login_trade_republic_item_url(item), headers: { "ACCEPT" => "application/json" }

    assert_response :success
    item.reload
    assert_predicate item, :good?
    assert_predicate item, :session_configured?
    assert_nil item.pending_login_state
    assert_nil item.phone_number
  end

  test "QR polling exposes transient provider failures as retryable" do
    item = families(:dylan_family).trade_republic_items.create!(
      name: "Trade Republic QR Connection",
      currency: "EUR",
      status: :requires_update
    )
    item.update!(pending_login_state: "qr-pending")
    provider = mock
    provider.expects(:poll_qr_login).with(pending_login_b64: "qr-pending").raises(
      Provider::TradeRepublicClient::Timeout,
      "Trade Republic WebSocket timed out"
    )
    TradeRepublicItem.any_instance.stubs(:trade_republic_provider).returns(provider)

    post poll_qr_login_trade_republic_item_url(item), headers: { "ACCEPT" => "application/json" }

    assert_response :service_unavailable
    assert_equal true, JSON.parse(response.body).fetch("retryable")
    assert_equal "qr-pending", item.reload.pending_login_state
  end

  test "successful web login renders a dialog button that closes the modal" do
    item = trade_republic_items(:requires_update_item)
    item.update!(pending_login_state: "pending-login")
    provider = mock
    provider.expects(:complete_login).with(pending_login_b64: "pending-login").returns(
      Provider::TradeRepublicClient::Result.new(
        data: { "status" => "confirmed", "session_txt" => "session" }
      )
    )
    TradeRepublicItem.any_instance.stubs(:trade_republic_provider).returns(provider)
    TradeRepublicItem.any_instance.stubs(:syncing?).returns(true)

    post poll_login_trade_republic_item_url(item), headers: { "ACCEPT" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_includes response.body, 'data-action="DS--dialog#close"'
    assert_includes response.body, I18n.t("settings.providers.trade_republic_panel.connection_success.close")
  end
end
