require "test_helper"

class ProviderConnectionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
    @connection = provider_connections(:monzo_connection)
  end

  test "show renders connection details" do
    get provider_connection_path(@connection)
    assert_response :success
  end

  test "setup renders account mapping form" do
    get setup_provider_connection_path(@connection)
    assert_response :success
  end

  test "save_setup redirects to show after syncing" do
    Provider::Connection.any_instance.expects(:sync_later).once
    post save_setup_provider_connection_path(@connection), params: { mappings: {} }
    assert_redirected_to provider_connection_path(@connection)
  end

  test "destroy removes connection and redirects" do
    delete provider_connection_path(@connection)
    assert_redirected_to settings_providers_path
    assert_raises(ActiveRecord::RecordNotFound) { @connection.reload }
  end

  test "reauth writes a reauth flow record and redirects to OAuth" do
    Provider::Auth::OAuth2.any_instance.stubs(:reauth_url).returns("https://auth.truelayer.com/?x=1")
    post reauth_provider_connection_path(@connection)
    assert_response :redirect
    assert_match "auth.truelayer.com", response.location

    flows = session[:provider_flows]
    assert flows.is_a?(Hash) && flows.any?
    flow = flows.values.first
    assert_equal "reauth", flow["kind"]
    assert_equal @connection.id, flow["connection_id"]
    assert_equal "truelayer", flow["provider_key"]
  end

  test "reauth on an EmbeddedLink connection redirects to the Link widget without writing an OAuth flow" do
    plaid_connection = Provider::Connection.create!(
      family:       @connection.family,
      provider_key: "plaid",
      auth_type:    "embedded_link",
      credentials:  { "access_token" => "tok_test" },
      status:       :requires_update,
      metadata:     { "region" => "us" }
    )

    post reauth_provider_connection_path(plaid_connection)

    assert_redirected_to new_provider_link_path(provider_key: "plaid", connection_id: plaid_connection.id)
    flows = session[:provider_flows]
    assert flows.blank? || flows.values.none? { |f| f["connection_id"] == plaid_connection.id },
      "EmbeddedLink reauth must not write an OAuth flow record"
  end

  test "save_setup creates a new account when mapping is 'new'" do
    pa = provider_accounts(:monzo_unlinked)
    Provider::Connection.any_instance.expects(:sync_later).once
    assert_difference "Account.count", 1 do
      post save_setup_provider_connection_path(@connection),
           params: { mappings: { pa.id => "new" } }
    end
    assert_redirected_to provider_connection_path(@connection)
    pa.reload
    assert pa.account_id.present?
    assert_equal "Monzo Savings", pa.account.name
    assert_equal "GBP", pa.account.currency
  end

  test "save_setup marks blank mappings as skipped" do
    pa = provider_accounts(:monzo_unlinked)
    Provider::Connection.any_instance.expects(:sync_later).once
    assert_no_difference "Account.count" do
      post save_setup_provider_connection_path(@connection),
           params: { mappings: { pa.id => "" } }
    end
    pa.reload
    assert_nil pa.account_id
    assert pa.skipped
  end

  test "non-admin cannot access setup" do
    sign_in users(:family_member)
    get setup_provider_connection_path(@connection)
    assert_redirected_to accounts_path
  end

  test "show includes setup link when connection has unlinked accounts" do
    # monzo_connection has monzo_unlinked which has no account_id
    get provider_connection_path(@connection)
    assert_response :success
    assert_select "a[href='#{setup_provider_connection_path(@connection)}']"
  end

  test "show omits setup link when all accounts are linked" do
    provider_accounts(:monzo_unlinked).update!(account: accounts(:depository))
    get provider_connection_path(@connection)
    assert_response :success
    assert_select "a[href='#{setup_provider_connection_path(@connection)}']", count: 0
  end

  test "sync enqueues a sync job and redirects" do
    Provider::Connection.any_instance.expects(:sync_later).once
    post sync_provider_connection_path(@connection)
    assert_redirected_to provider_connection_path(@connection)
  end

  test "link action links provider account to sure account" do
    Provider::Connection.any_instance.stubs(:sync_later)
    pa = provider_accounts(:monzo_unlinked)
    account = accounts(:depository)
    post link_provider_connections_path(provider_account_id: pa.id, account_id: account.id)
    assert_redirected_to provider_connection_path(pa.provider_connection)
    assert_equal account.id, pa.reload.account_id
    assert_not pa.reload.skipped?
  end

  test "skip action marks provider account as skipped" do
    pa = provider_accounts(:monzo_unlinked)
    post skip_provider_connections_path(provider_account_id: pa.id)
    assert_redirected_to provider_connection_path(pa.provider_connection)
    assert pa.reload.skipped?
  end

  test "link action returns not found for another family's provider account" do
    other_family = families(:empty)
    other_conn = Provider::Connection.create!(
      family: other_family, provider_key: "truelayer", auth_type: "oauth2",
      credentials: {}, status: :healthy
    )
    other_pa = Provider::Account.create!(
      provider_connection: other_conn, external_id: "acc_other",
      external_name: "Other Account", external_type: "depository", currency: "GBP"
    )
    post link_provider_connections_path(provider_account_id: other_pa.id, account_id: accounts(:depository).id)
    assert_response :not_found
  end

  test "skip action returns not found for another family's provider account" do
    other_family = families(:empty)
    other_conn = Provider::Connection.create!(
      family: other_family, provider_key: "truelayer", auth_type: "oauth2",
      credentials: {}, status: :healthy
    )
    other_pa = Provider::Account.create!(
      provider_connection: other_conn, external_id: "acc_other_skip",
      external_name: "Other Account", external_type: "depository", currency: "GBP"
    )
    post skip_provider_connections_path(provider_account_id: other_pa.id)
    assert_response :not_found
  end
end
