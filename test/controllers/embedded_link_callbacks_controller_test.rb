require "test_helper"

class EmbeddedLinkCallbacksControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
    @family = families(:dylan_family)
    @plaid_client = mock
    Provider::Registry.stubs(:plaid_provider_for_region).returns(@plaid_client)
  end

  test "new returns 400 for unknown region" do
    @plaid_client.expects(:get_link_token).never
    get new_provider_link_path(provider_key: "plaid", region: "asia")
    assert_response :bad_request
  end

  test "new returns 404 for non-EmbeddedLink provider_key" do
    get new_provider_link_path(provider_key: "truelayer")
    assert_response :not_found
  end

  test "new returns 404 for unknown provider_key" do
    get new_provider_link_path(provider_key: "no_such_provider")
    assert_response :not_found
  end

  test "new (new flow) issues link_token and stashes flow and active link flow" do
    @plaid_client.expects(:get_link_token).returns(OpenStruct.new(link_token: "link_tok_abc"))
    get new_provider_link_path(provider_key: "plaid", region: "us")
    assert_response :success

    flows = session[:provider_flows]
    assert flows.is_a?(Hash) && flows.size == 1
    flow = flows.values.first
    assert_equal "new", flow["kind"]
    assert_equal "us", flow["region"]
    assert_equal "link_tok_abc", flow["link_token"]
    assert_equal flows.keys.first, session.dig(:active_link_flows, "plaid")
  end

  test "new (update flow) opens Link in update mode for existing connection" do
    conn = Provider::Connection.create!(
      family: @family, provider_key: "plaid", auth_type: "embedded_link",
      credentials: { "access_token" => "existing_token" },
      metadata: { "region" => "us" }, status: :requires_update
    )
    @plaid_client.expects(:get_link_token)
                 .with(has_entry(access_token: "existing_token"))
                 .returns(OpenStruct.new(link_token: "update_tok"))

    get new_provider_link_path(provider_key: "plaid", connection_id: conn.id)
    assert_response :success

    flow = session[:provider_flows].values.first
    assert_equal "update", flow["kind"]
    assert_equal conn.id, flow["connection_id"]
  end

  test "create exchanges public_token, creates connection, redirects to setup" do
    @plaid_client.expects(:get_link_token).returns(OpenStruct.new(link_token: "lt"))
    get new_provider_link_path(provider_key: "plaid", region: "us")
    flow_id = session[:provider_flows].keys.first

    @plaid_client.expects(:exchange_public_token)
                 .with("public_token_abc")
                 .returns(OpenStruct.new(access_token: "tok_new", item_id: "item_new"))
    Provider::Connection.any_instance.expects(:discover_accounts!).once

    assert_difference "Provider::Connection.count", 1 do
      post finish_provider_link_path(provider_key: "plaid", flow_id: flow_id),
           params: { public_token: "public_token_abc", flow_id: flow_id }
    end
    conn = Provider::Connection.order(created_at: :desc).first
    assert_equal "plaid", conn.provider_key
    assert_equal "us", conn.metadata["region"]
    assert_equal "embedded_link", conn.auth_type
    assert_equal "tok_new", conn.credentials["access_token"]
    assert_equal "item_new", conn.metadata["plaid_item_id"]
    assert_redirected_to setup_provider_connection_path(conn)

    # Flow consumed.
    assert_nil session[:provider_flows][flow_id]
    assert_nil session.dig(:active_link_flows, "plaid")
  end

  test "create rejects unknown flow_id without creating a connection" do
    assert_no_difference "Provider::Connection.count" do
      post finish_provider_link_path(provider_key: "plaid", flow_id: "unknown"),
           params: { public_token: "tok" }
    end
    assert_redirected_to settings_providers_path
  end

  test "create with already-consumed flow_id rejects (no replay)" do
    @plaid_client.expects(:get_link_token).returns(OpenStruct.new(link_token: "lt"))
    get new_provider_link_path(provider_key: "plaid", region: "us")
    flow_id = session[:provider_flows].keys.first

    @plaid_client.stubs(:exchange_public_token)
                 .returns(OpenStruct.new(access_token: "t", item_id: "i"))
    Provider::Connection.any_instance.stubs(:discover_accounts!)

    post finish_provider_link_path(provider_key: "plaid", flow_id: flow_id),
         params: { public_token: "p1", flow_id: flow_id }
    assert_no_difference "Provider::Connection.count" do
      post finish_provider_link_path(provider_key: "plaid", flow_id: flow_id),
           params: { public_token: "p2", flow_id: flow_id }
    end
  end
end
