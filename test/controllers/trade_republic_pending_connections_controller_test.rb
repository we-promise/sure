require "test_helper"

class TradeRepublicPendingConnectionsControllerTest < ActionDispatch::IntegrationTest
  TURBO_STREAM = { "ACCEPT" => "text/vnd.turbo-stream.html" }.freeze

  setup do
    sign_in users(:family_admin)
    @family = families(:dylan_family)
  end

  test "new opens the add-connection form in the drawer" do
    get new_trade_republic_pending_connection_url, headers: { "Turbo-Frame" => "drawer" }

    assert_response :success
    assert_select "turbo-frame#drawer #trade-republic-new-connection form[action='#{trade_republic_pending_connections_path}']"
  end

  test "a QR login creates no connection until Trade Republic approves it" do
    stub_provider(initiate_qr_login: result("status" => "qr_pending", "pending_login_b64" => "qr-pending"), login_stage: "qr_pending")

    assert_no_difference "TradeRepublicItem.count" do
      assert_difference "TradeRepublicPendingConnection.count", 1 do
        post trade_republic_pending_connections_url, params: { login_method: "qr" }, headers: TURBO_STREAM
      end
    end

    assert_response :success
    assert_equal "qr-pending", @family.trade_republic_pending_connections.last.pending_login_state
    assert_turbo_stream action: "replace", target: "trade-republic-providers-panel"
    assert_turbo_stream action: "replace", target: "drawer", count: 0
  end

  test "a connection added from the drawer closes it once its login started" do
    stub_provider(initiate_qr_login: result("status" => "qr_pending", "pending_login_b64" => "qr-pending"), login_stage: "qr_pending")

    post trade_republic_pending_connections_url, params: { login_method: "qr", in_drawer: "1" }, headers: TURBO_STREAM

    assert_turbo_stream action: "replace", target: "drawer"
  end

  test "a phone number and PIN login waits for approval without creating a connection" do
    stub_provider(initiate_login: result("status" => "pending", "pending_login_b64" => "push-pending"), login_stage: "waiting_for_approval")

    assert_no_difference "TradeRepublicItem.count" do
      post trade_republic_pending_connections_url, params: {
        trade_republic_pending_connection: { phone_number: "+491701234567", pin: "1234" }
      }, headers: TURBO_STREAM
    end

    pending_connection = @family.trade_republic_pending_connections.last
    assert_equal "push-pending", pending_connection.pending_login_state
    assert_equal "+491701234567", pending_connection.phone_number
  end

  test "a new login replaces one left unfinished" do
    stale = @family.trade_republic_pending_connections.create!(qr_login: true, pending_login_state: "stale")
    stub_provider(initiate_qr_login: result("status" => "qr_pending", "pending_login_b64" => "qr-pending"), login_stage: "qr_pending")

    post trade_republic_pending_connections_url, params: { login_method: "qr" }, headers: TURBO_STREAM

    assert_not TradeRepublicPendingConnection.exists?(stale.id)
    assert_equal 1, @family.trade_republic_pending_connections.count
  end

  test "a login without a PIN is rejected before Trade Republic is asked" do
    assert_no_difference "TradeRepublicPendingConnection.count" do
      post trade_republic_pending_connections_url, params: {
        trade_republic_pending_connection: { phone_number: "+491701234567", pin: "" }
      }
    end

    assert_redirected_to settings_providers_path(anchor: "trade-republic")
    assert_equal I18n.t("trade_republic_items.initiate_login.pin_required"), flash[:alert]
  end

  test "a failed attempt shows its error in the panel and the drawer with the phone number kept" do
    post trade_republic_pending_connections_url, params: {
      trade_republic_pending_connection: { phone_number: "+491701234567", pin: "" }
    }, headers: TURBO_STREAM

    assert_turbo_stream status: :unprocessable_entity, action: "replace", target: "trade-republic-providers-panel"
    assert_turbo_stream status: :unprocessable_entity, action: "replace", target: "trade-republic-new-connection" do
      assert_select "input[name='trade_republic_pending_connection[phone_number]'][value='+491701234567']"
    end
    assert_includes response.body, I18n.t("trade_republic_items.initiate_login.pin_required")
  end

  test "an approved QR login creates the connection with the login's device ID" do
    pending_connection = @family.trade_republic_pending_connections.create!(qr_login: true, currency: "EUR", pending_login_state: "qr-pending")
    stub_provider(poll_qr_login: result("status" => "ok", "session_txt" => "qr-session", "account" => { "brokerage_account_id" => "DE5555" }))

    assert_difference "TradeRepublicItem.count", 1 do
      post poll_qr_login_trade_republic_pending_connection_url(pending_connection), headers: { "ACCEPT" => "application/json" }
    end

    assert_response :success
    item = @family.trade_republic_items.order(:created_at).last
    assert_predicate item, :good?
    assert_equal "qr-session", item.session_blob
    assert_equal "DE5555", item.brokerage_account_id
    assert_equal pending_connection.device_id, item.device_id
    assert_not TradeRepublicPendingConnection.exists?(pending_connection.id)
  end

  test "an approved push login creates the connection" do
    pending_connection = @family.trade_republic_pending_connections.create!(phone_number: "+491701234567", currency: "EUR", pending_login_state: "push-pending")
    stub_provider(complete_login: result("status" => "ok", "session_txt" => "push-session", "account" => { "brokerage_account_id" => "DE6666" }))

    assert_difference "TradeRepublicItem.count", 1 do
      post poll_login_trade_republic_pending_connection_url(pending_connection), headers: TURBO_STREAM
    end

    item = @family.trade_republic_items.order(:created_at).last
    assert_equal "+491701234567", item.phone_number
    assert_not TradeRepublicPendingConnection.exists?(pending_connection.id)
    assert_turbo_stream action: "replace", target: "modal"
    assert_turbo_stream action: "replace", target: "trade-republic-providers-panel"
  end

  test "a login for an account that is already connected creates nothing" do
    pending_connection = @family.trade_republic_pending_connections.create!(qr_login: true, pending_login_state: "qr-pending")
    @family.trade_republic_items.create!(name: "Trade Republic", currency: "EUR", status: :good, session_blob: "session", brokerage_account_id: "DE7777")
    stub_provider(poll_qr_login: result("status" => "ok", "session_txt" => "dup-session", "account" => { "brokerage_account_id" => "DE7777" }))

    assert_no_difference "TradeRepublicItem.count" do
      post poll_qr_login_trade_republic_pending_connection_url(pending_connection), headers: { "ACCEPT" => "application/json" }
    end

    assert_equal "duplicate_connection", JSON.parse(response.body).fetch("status")
    assert_not TradeRepublicPendingConnection.exists?(pending_connection.id)
  end

  test "a lapsed QR login keeps its row so it can start again" do
    pending_connection = @family.trade_republic_pending_connections.create!(qr_login: true, pending_login_state: "qr-pending")
    provider = stub_provider
    provider.expects(:poll_qr_login).raises(Provider::TradeRepublicClient::LoginExpired, "expired")

    post poll_qr_login_trade_republic_pending_connection_url(pending_connection), headers: { "ACCEPT" => "application/json" }

    assert_response :unprocessable_entity, response.body
    assert_nil pending_connection.reload.pending_login_state
  end

  test "a lapsed QR login starts again from its row" do
    pending_connection = @family.trade_republic_pending_connections.create!(qr_login: true)
    stub_provider(initiate_qr_login: result("status" => "qr_pending", "pending_login_b64" => "qr-restarted"))

    post initiate_qr_login_trade_republic_pending_connection_url(pending_connection), headers: { "ACCEPT" => "application/json" }

    assert_response :accepted
    assert_equal "qr-restarted", pending_connection.reload.pending_login_state
  end

  test "the login is started and polled with the same device ID" do
    device_ids = []
    Provider::TradeRepublicClient.stubs(:new).with { |**options| device_ids << options[:device_id] }.returns(
      stub(initiate_qr_login: result("status" => "qr_pending", "pending_login_b64" => "qr-pending"), login_stage: "qr_pending", qr_login?: true, login_method: "qr")
    )

    post trade_republic_pending_connections_url, params: { login_method: "qr" }, headers: TURBO_STREAM
    pending_connection = @family.trade_republic_pending_connections.last
    pending_connection.trade_republic_provider

    assert device_ids.first.present?
    assert_equal [ pending_connection.device_id ], device_ids.uniq
  end

  test "cancelling the QR login removes the pending connection" do
    pending_connection = @family.trade_republic_pending_connections.create!(qr_login: true, pending_login_state: "qr-pending")

    post cancel_qr_login_trade_republic_pending_connection_url(pending_connection), headers: TURBO_STREAM

    assert_turbo_stream action: "replace", target: "trade-republic-providers-panel"
    assert_not TradeRepublicPendingConnection.exists?(pending_connection.id)
  end

  test "cancelling a phone number and PIN login removes the pending connection" do
    pending_connection = @family.trade_republic_pending_connections.create!(phone_number: "+491701234567", pending_login_state: "push-pending")

    delete trade_republic_pending_connection_url(pending_connection), headers: TURBO_STREAM

    assert_turbo_stream action: "replace", target: "trade-republic-providers-panel"
    assert_not TradeRepublicPendingConnection.exists?(pending_connection.id)
  end

  test "another family's pending connection cannot be touched" do
    other = families(:empty).trade_republic_pending_connections.create!(qr_login: true, pending_login_state: "qr-pending")

    delete trade_republic_pending_connection_url(other)

    assert_response :not_found
    assert TradeRepublicPendingConnection.exists?(other.id)
  end

  private

    def result(data)
      Provider::TradeRepublicClient::Result.new(data: data)
    end

    def stub_provider(login_stage: nil, **returns)
      provider = mock
      returns.each { |method, value| provider.stubs(method).returns(value) }
      provider.stubs(:login_stage).returns(login_stage)
      provider.stubs(:qr_login?).returns(false)
      provider.stubs(:login_method).returns(nil)
      TradeRepublicPendingConnection.any_instance.stubs(:trade_republic_provider).returns(provider)
      provider
    end
end
