require "test_helper"

class SnaptradeItemsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    @snaptrade_item = snaptrade_items(:configured_item)
  end

  def sign_out
    @user.sessions.each do |session|
      delete session_path(session)
    end
  end

  def sign_in_legacy_family
    sign_out
    sign_in @user = users(:empty)
    snaptrade_items(:legacy_oauth_item)
  end

  def with_oauth_app_configured
    Rails.configuration.x.snaptrade.oauth_client_id = "client-id"
    Rails.configuration.x.snaptrade.oauth_client_secret = "client-secret"
    yield
  ensure
    Rails.configuration.x.snaptrade.oauth_client_id = nil
    Rails.configuration.x.snaptrade.oauth_client_secret = nil
  end

  # --- Credentials ---

  test "create saves api credentials and registers a SnapTrade user" do
    sign_in_legacy_family
    SnaptradeItem.any_instance.expects(:ensure_user_registered!).once.returns(true)

    assert_difference "SnaptradeItem.count", 1 do
      post snaptrade_items_url, params: {
        snaptrade_item: { client_id: "cid", consumer_key: "ck" }
      }
    end

    item = SnaptradeItem.order(:created_at).last
    assert_equal "cid", item.client_id
    assert item.device_flow?
  end

  test "create surfaces validation errors without registering" do
    sign_in_legacy_family
    SnaptradeItem.any_instance.expects(:ensure_user_registered!).never

    assert_no_difference "SnaptradeItem.count" do
      post snaptrade_items_url, params: { snaptrade_item: { client_id: "cid" } }
    end

    assert_response :redirect
    assert flash[:alert].present?
  end

  test "create still saves credentials when registration fails" do
    sign_in_legacy_family
    SnaptradeItem.any_instance.expects(:ensure_user_registered!)
      .raises(Provider::Snaptrade::ApiError.new("rate limited", status_code: 429))

    assert_difference "SnaptradeItem.count", 1 do
      post snaptrade_items_url, params: {
        snaptrade_item: { client_id: "cid", consumer_key: "ck" }
      }
    end

    assert_equal "cid", SnaptradeItem.order(:created_at).last.client_id
  end

  test "update replaces api credentials on an existing item" do
    SnaptradeItem.any_instance.stubs(:ensure_user_registered!).returns(true)

    patch snaptrade_item_url(@snaptrade_item), params: {
      snaptrade_item: { client_id: "new-cid", consumer_key: "new-ck" }
    }

    assert_equal "new-cid", @snaptrade_item.reload.client_id
  end

  # --- Connection portal ---

  test "connect redirects to portal when successful" do
    portal_url = "https://app.snaptrade.com/portal/test123"

    SnaptradeItem.any_instance.stubs(:connection_portal_url).returns(portal_url)

    get connect_snaptrade_item_url(@snaptrade_item)

    assert_redirected_to portal_url
  end

  test "connect handles decryption error gracefully" do
    SnaptradeItem.any_instance
      .stubs(:connection_portal_url)
      .raises(ActiveRecord::Encryption::Errors::Decryption.new("cannot decrypt"))

    get connect_snaptrade_item_url(@snaptrade_item)

    assert_redirected_to settings_providers_path
    assert_match(/Unable to read SnapTrade credentials/, flash[:alert])
  end

  test "connect handles general error gracefully" do
    SnaptradeItem.any_instance
      .stubs(:connection_portal_url)
      .raises(StandardError.new("something broke"))

    get connect_snaptrade_item_url(@snaptrade_item)

    assert_redirected_to settings_providers_path
    assert_match(/Failed to connect/, flash[:alert])
  end

  test "connect registers the SnapTrade user first when the device flow has not yet" do
    @snaptrade_item.update!(snaptrade_user_id: nil, snaptrade_user_secret: nil)
    SnaptradeItem.any_instance.expects(:ensure_user_registered!).once.returns(true)
    SnaptradeItem.any_instance.stubs(:connection_portal_url).returns("https://app.snaptrade.com/portal/x")

    get connect_snaptrade_item_url(@snaptrade_item)

    assert_response :redirect
  end

  test "connect does not try to register a deprecated PKCE connection" do
    legacy_item = sign_in_legacy_family
    SnaptradeItem.any_instance.expects(:ensure_user_registered!).never
    SnaptradeItem.any_instance.stubs(:connection_portal_url).returns("https://app.snaptrade.com/portal/x")

    get connect_snaptrade_item_url(legacy_item)

    assert_response :redirect
  end

  # --- OAuth device flow ---

  test "oauth_connect renders the device flow drawer" do
    Rails.configuration.x.snaptrade.oauth_client_id = "public-client-id"

    get oauth_connect_snaptrade_items_url(item_id: @snaptrade_item.id)

    assert_response :success
    assert_match(/Start authorization/, response.body)
  ensure
    Rails.configuration.x.snaptrade.oauth_client_id = nil
  end

  test "oauth_connect explains a missing public client id" do
    Rails.configuration.x.snaptrade.oauth_client_id = nil

    get oauth_connect_snaptrade_items_url

    assert_response :unprocessable_entity
    assert_match(/SNAPTRADE_OAUTH_CLIENT_ID/, response.body)
  end

  test "oauth_connect asks for API credentials before starting the ceremony" do
    Rails.configuration.x.snaptrade.oauth_client_id = "public-client-id"
    item = @user.family.snaptrade_items.create!(name: "No credentials yet")

    get oauth_connect_snaptrade_items_url(item_id: item.id)

    assert_response :unprocessable_entity
    assert_match(/Client ID and Consumer Key/, response.body)
  ensure
    Rails.configuration.x.snaptrade.oauth_client_id = nil
  end

  # Device-flow tokens land in the same oauth_* columns a PKCE connection runs
  # on, so starting the ceremony against one would destroy a working connection.
  test "the device flow refuses to run against a deprecated PKCE connection" do
    legacy_item = sign_in_legacy_family
    Rails.configuration.x.snaptrade.oauth_client_id = "public-client-id"
    original_token = legacy_item.oauth_access_token
    SnaptradeItem.any_instance.expects(:start_oauth_device_flow).never

    post start_oauth_connect_snaptrade_items_url, params: { item_id: legacy_item.id }

    assert_response :unprocessable_entity
    assert_match(/Client ID and Consumer Key/, response.body)
    assert_equal original_token, legacy_item.reload.oauth_access_token
  ensure
    Rails.configuration.x.snaptrade.oauth_client_id = nil
  end

  test "complete_oauth_device_flow will not overwrite a deprecated PKCE connection's tokens" do
    legacy_item = sign_in_legacy_family
    original_token = legacy_item.oauth_access_token
    SnaptradeItem.any_instance.expects(:complete_oauth_device_flow!).never

    post complete_oauth_device_flow_snaptrade_item_url(legacy_item), params: { device_code: "dc" }

    assert_response :unprocessable_entity
    assert_equal original_token, legacy_item.reload.oauth_access_token
  end

  test "start_oauth_connect shows the device code" do
    Rails.configuration.x.snaptrade.oauth_client_id = "public-client-id"
    SnaptradeItem.any_instance.expects(:start_oauth_device_flow).with(scope: "read").returns(
      "device_code" => "dc", "user_code" => "WXYZ", "verification_uri" => "https://snaptrade.test/device"
    )

    post start_oauth_connect_snaptrade_items_url, params: { item_id: @snaptrade_item.id }

    assert_response :success
    assert_match(/WXYZ/, response.body)
  ensure
    Rails.configuration.x.snaptrade.oauth_client_id = nil
  end

  test "start_oauth_connect rejects an unsupported scope" do
    Rails.configuration.x.snaptrade.oauth_client_id = "public-client-id"
    SnaptradeItem.any_instance.expects(:start_oauth_device_flow).with(scope: "read").returns({})

    post start_oauth_connect_snaptrade_items_url, params: { item_id: @snaptrade_item.id, scope: "trade" }

    assert_response :success
  ensure
    Rails.configuration.x.snaptrade.oauth_client_id = nil
  end

  test "complete_oauth_device_flow stores tokens and queues a sync" do
    SnaptradeItem.any_instance.expects(:complete_oauth_device_flow!)
      .with(device_code: "dc")
      .returns({ "access_token" => "at", "token_type" => "Bearer" })

    assert_difference "Sync.count", 1 do
      post complete_oauth_device_flow_snaptrade_item_url(@snaptrade_item), params: { device_code: "dc" }
    end

    assert_redirected_to setup_accounts_snaptrade_item_path(@snaptrade_item, accountable_type: nil, return_to: nil)
  end

  test "complete_oauth_device_flow requires a device code" do
    SnaptradeItem.any_instance.expects(:complete_oauth_device_flow!).never

    post complete_oauth_device_flow_snaptrade_item_url(@snaptrade_item), params: {}, as: :json

    assert_response :unprocessable_entity
  end

  test "complete_oauth_device_flow re-renders the drawer when authorization is still pending" do
    SnaptradeItem.any_instance.expects(:complete_oauth_device_flow!).raises(
      Provider::Snaptrade::ApiError.new(
        "pending", status_code: 400,
        response_body: { error: "authorization_pending", error_description: "Not yet approved" }.to_json
      )
    )

    post complete_oauth_device_flow_snaptrade_item_url(@snaptrade_item), params: { device_code: "dc" }

    assert_response :bad_request
    assert_match(/Not yet approved/, response.body)
  end

  test "complete_oauth_device_flow reports when credentials are still missing" do
    item = @user.family.snaptrade_items.create!(name: "No credentials yet")
    SnaptradeItem.any_instance.expects(:complete_oauth_device_flow!).never

    post complete_oauth_device_flow_snaptrade_item_url(item), params: { device_code: "dc" }

    assert_response :unprocessable_entity
    assert_match(/Client ID and Consumer Key/, response.body)
  end

  # --- DEPRECATED authorization-code + PKCE flow ---

  test "oauth_authorize sends a device-flow item to the device flow instead" do
    with_oauth_app_configured do
      get oauth_authorize_snaptrade_items_url(item_id: @snaptrade_item.id)

      assert_redirected_to oauth_connect_snaptrade_items_path(return_to: nil, accountable_type: nil)
      assert_match(/no longer used for new connections/, flash[:notice])
      assert_nil session[:snaptrade_oauth]
    end
  end

  test "oauth_authorize refuses to start a brand new PKCE authorization" do
    with_oauth_app_configured do
      assert_no_difference "SnaptradeItem.count" do
        get oauth_authorize_snaptrade_items_url
      end

      assert_redirected_to oauth_connect_snaptrade_items_path(return_to: nil, accountable_type: nil)
      assert_nil session[:snaptrade_oauth]
    end
  end

  test "oauth_authorize lets an existing PKCE connection re-consent" do
    legacy_item = sign_in_legacy_family

    with_oauth_app_configured do
      get oauth_authorize_snaptrade_items_url(item_id: legacy_item.id)

      assert_response :redirect
      redirect = URI.parse(response.location)
      assert_equal "dashboard.snaptrade.com", redirect.host
      params = Rack::Utils.parse_query(redirect.query)
      oauth_session = session[:snaptrade_oauth]
      assert_equal oauth_session["state"], params["state"]
      assert_equal "S256", params["code_challenge_method"]
      assert oauth_session["code_verifier"].present?
      assert_equal legacy_item.id, oauth_session["item_id"]
    end
  end

  test "oauth_authorize redirects to settings when the OAuth app is not configured" do
    legacy_item = sign_in_legacy_family
    Rails.configuration.x.snaptrade.oauth_client_id = nil
    Rails.configuration.x.snaptrade.oauth_client_secret = nil

    get oauth_authorize_snaptrade_items_url(item_id: legacy_item.id)

    assert_redirected_to settings_providers_path
    assert flash[:alert].present?
  end

  test "oauth_callback rejects state mismatch without exchanging the code" do
    legacy_item = sign_in_legacy_family
    Provider::SnaptradeOauth.expects(:exchange_code).never

    with_oauth_app_configured do
      get oauth_authorize_snaptrade_items_url(item_id: legacy_item.id)

      get oauth_callback_snaptrade_items_url(code: "c0de", state: "wrong-state")

      assert_redirected_to settings_providers_path
      assert flash[:alert].present?
    end
  end

  test "oauth_callback handles access_denied" do
    get oauth_callback_snaptrade_items_url(error: "access_denied", state: "whatever")
    assert_redirected_to settings_providers_path
    assert flash[:alert].present?
  end

  test "oauth_callback fails when code param is missing" do
    legacy_item = sign_in_legacy_family
    Provider::SnaptradeOauth.expects(:exchange_code).never

    with_oauth_app_configured do
      get oauth_authorize_snaptrade_items_url(item_id: legacy_item.id)
      oauth_session = session[:snaptrade_oauth]

      get oauth_callback_snaptrade_items_url(state: oauth_session["state"])

      assert_redirected_to settings_providers_path
      assert_equal "Unable to complete SnapTrade authorization. Please try again.", flash[:alert]
      assert_nil session[:snaptrade_oauth]
    end
  end

  test "oauth_callback handles exchange failures without applying tokens" do
    legacy_item = sign_in_legacy_family
    original_token = legacy_item.oauth_access_token

    with_oauth_app_configured do
      get oauth_authorize_snaptrade_items_url(item_id: legacy_item.id)
      oauth_session = session[:snaptrade_oauth]

      Provider::SnaptradeOauth.expects(:exchange_code)
        .with(code: "c0de", redirect_uri: oauth_callback_snaptrade_items_url, code_verifier: oauth_session["code_verifier"])
        .raises(Provider::Snaptrade::Error.new("upstream exchange failed"))

      get oauth_callback_snaptrade_items_url(code: "c0de", state: oauth_session["state"])

      assert_redirected_to settings_providers_path
      assert_equal "Unable to complete SnapTrade authorization. Please try again.", flash[:alert]
      assert_nil session[:snaptrade_oauth]
      assert_equal original_token, legacy_item.reload.oauth_access_token
    end
  end

  test "oauth_callback exchanges code, stores tokens, queues sync, and resumes setup" do
    legacy_item = sign_in_legacy_family

    with_oauth_app_configured do
      get oauth_authorize_snaptrade_items_url(item_id: legacy_item.id, return_to: "setup_accounts")
      oauth_session = session[:snaptrade_oauth]

      Provider::SnaptradeOauth.expects(:exchange_code)
        .with(code: "c0de", redirect_uri: oauth_callback_snaptrade_items_url, code_verifier: oauth_session["code_verifier"])
        .returns({ "access_token" => "at", "refresh_token" => "rt", "expires_in" => 900 })

      get oauth_callback_snaptrade_items_url(code: "c0de", state: oauth_session["state"])

      assert_redirected_to setup_accounts_snaptrade_item_path(legacy_item, accountable_type: nil)
      assert_equal "at", legacy_item.reload.oauth_access_token
      assert_nil session[:snaptrade_oauth]
    end
  end

  test "oauth_callback clears a reconnect warning after successful authorization" do
    legacy_item = sign_in_legacy_family
    legacy_item.update!(status: :requires_update)

    with_oauth_app_configured do
      get oauth_authorize_snaptrade_items_url(item_id: legacy_item.id)
      oauth_session = session[:snaptrade_oauth]
      Provider::SnaptradeOauth.expects(:exchange_code).returns({ "access_token" => "at", "refresh_token" => "rt" })

      get oauth_callback_snaptrade_items_url(code: "c0de", state: oauth_session["state"])

      assert legacy_item.reload.good?
    end
  end

  test "oauth_callback queues a sync even while activities are fetching" do
    legacy_item = sign_in_legacy_family

    with_oauth_app_configured do
      get oauth_authorize_snaptrade_items_url(item_id: legacy_item.id)
      oauth_session = session[:snaptrade_oauth]
      Provider::SnaptradeOauth.expects(:exchange_code).returns({ "access_token" => "at", "refresh_token" => "rt" })
      active_sync = legacy_item.syncs.create!
      active_sync.start!

      assert_enqueued_with job: SnaptradeFollowUpSyncJob do
        get oauth_callback_snaptrade_items_url(code: "c0de", state: oauth_session["state"])
      end
    end
  end

  # --- Entry points ---

  test "Reconnect starts the device flow instead of adding a brokerage" do
    @snaptrade_item.update!(status: :requires_update)

    get accounts_url

    assert_select "a[href='#{oauth_connect_snaptrade_items_path(item_id: @snaptrade_item.id)}'][data-turbo-frame='_top']", text: /Reconnect/
    assert_select "a[href='#{connect_snaptrade_item_path(@snaptrade_item)}']", text: /Reconnect/, count: 0
  end

  test "select_accounts redirects unconnected users into the device flow" do
    sign_out
    sign_in @user = users(:empty)
    snaptrade_items(:legacy_oauth_item).destroy!
    snaptrade_item = snaptrade_items(:unauthorized_item)

    get select_accounts_snaptrade_items_url, params: { accountable_type: "Investment", return_to: "setup_accounts" }

    assert_redirected_to oauth_connect_snaptrade_items_path(
      item_id: snaptrade_item.id,
      accountable_type: "Investment",
      return_to: "setup_accounts"
    )
  end

  test "select_accounts sends a deprecated PKCE connection straight to setup" do
    legacy_item = sign_in_legacy_family

    get select_accounts_snaptrade_items_url, params: { accountable_type: "Investment", return_to: "/accounts" }

    assert_redirected_to setup_accounts_snaptrade_item_path(legacy_item, accountable_type: "Investment", return_to: "/accounts")
  end

  test "select_accounts redirects registered users to setup flow" do
    get select_accounts_snaptrade_items_url, params: { accountable_type: "Investment", return_to: "/accounts" }

    assert_redirected_to setup_accounts_snaptrade_item_path(@snaptrade_item, accountable_type: "Investment", return_to: "/accounts")
  end

  test "preload_accounts redirects unconnected users into the device flow" do
    sign_out
    sign_in @user = users(:empty)
    snaptrade_items(:legacy_oauth_item).destroy!

    assert_no_difference "Sync.count" do
      get preload_accounts_snaptrade_items_url
    end

    assert_redirected_to oauth_connect_snaptrade_items_path(item_id: snaptrade_items(:unauthorized_item).id)
  end

  test "preload_accounts redirects registered users to setup flow and queues sync" do
    assert_difference "Sync.count", 1 do
      get preload_accounts_snaptrade_items_url
    end

    assert_redirected_to setup_accounts_snaptrade_item_path(@snaptrade_item)
  end

  test "entry routing prefers a connected active item over a pending one" do
    pending_item = @user.family.snaptrade_items.create!(
      name: "Pending Registration",
      client_id: "pending-cid",
      consumer_key: "pending-ck",
      status: :good,
      scheduled_for_deletion: false,
      pending_account_setup: true
    )

    get select_accounts_snaptrade_items_url, params: { accountable_type: "Investment", return_to: "/accounts" }
    assert_redirected_to setup_accounts_snaptrade_item_path(@snaptrade_item, accountable_type: "Investment", return_to: "/accounts")

    assert_difference "Sync.count", 1 do
      get preload_accounts_snaptrade_items_url
    end
    assert_redirected_to setup_accounts_snaptrade_item_path(@snaptrade_item)

    assert_not pending_item.fully_configured?
  end

  # --- Account setup ---

  test "setup_accounts shows linkable investment and crypto accounts in dropdown" do
    get setup_accounts_snaptrade_item_url(@snaptrade_item)

    assert_response :success

    # Investment and crypto accounts (no provider) should appear in the link dropdown
    assert_match accounts(:investment).name, response.body
    assert_match accounts(:crypto).name, response.body

    # Depository should NOT appear in the link dropdown (wrong type)
    # The depository name may appear elsewhere on the page, so check the select options specifically
    refute_match(/option.*#{accounts(:depository).name}/, response.body)
  end

  test "setup_accounts excludes accounts that already have a provider from dropdown" do
    # Link the investment account to a snaptrade_account
    AccountProvider.create!(
      account: accounts(:investment),
      provider: snaptrade_accounts(:fidelity_401k)
    )

    get setup_accounts_snaptrade_item_url(@snaptrade_item)

    assert_response :success

    # Investment account is now linked → should NOT appear in link dropdown options
    refute_match(/option.*#{accounts(:investment).name}/, response.body)
    # Crypto still unlinked → should appear
    assert_match accounts(:crypto).name, response.body
  end

  test "setup_accounts preselects types from SnapTrade account categories" do
    account = snaptrade_accounts(:fidelity_401k)
    account.update!(raw_payload: { "account_category" => "DEPOSIT" })

    get setup_accounts_snaptrade_item_url(@snaptrade_item)

    assert_select "input[name='account_types[#{account.id}]'][value='Depository']"
  end

  test "complete_account_setup uses the selected account type" do
    account = snaptrade_accounts(:fidelity_401k)
    @snaptrade_item.stubs(:sync_later)

    assert_difference "Account.where(accountable_type: 'Depository').count", 1 do
      post complete_account_setup_snaptrade_item_url(@snaptrade_item), params: {
        account_ids: [ account.id ],
        account_types: { account.id => "Depository" }
      }
    end

    assert_equal "Depository", account.reload.current_account.accountable_type
  end

  test "select_existing_account prefers a connected active item over a pending one" do
    pending_item = @user.family.snaptrade_items.create!(
      name: "Pending Registration",
      status: :good,
      scheduled_for_deletion: false,
      pending_account_setup: true
    )
    pending_item.snaptrade_accounts.create!(
      snaptrade_account_id: "pending_snaptrade_account",
      name: "Pending Brokerage Account",
      brokerage_name: "Pending Broker",
      currency: "USD",
      current_balance: 0
    )

    get select_existing_account_snaptrade_items_url, params: { account_id: accounts(:investment).id }

    assert_response :success
    assert_includes response.body, snaptrade_accounts(:fidelity_401k).name
    refute_includes response.body, "Pending Brokerage Account"
  end

  test "link_existing_account links account to snaptrade_account" do
    account = accounts(:investment)
    snaptrade_account = snaptrade_accounts(:fidelity_401k)

    assert_difference "AccountProvider.count", 1 do
      post link_existing_account_snaptrade_items_url, params: {
        account_id: account.id,
        snaptrade_account_id: snaptrade_account.id,
        snaptrade_item_id: @snaptrade_item.id
      }
    end

    assert_redirected_to account_path(account)
    assert_match(/Successfully linked/, flash[:notice])

    snaptrade_account.reload
    assert_equal account, snaptrade_account.current_account
  end

  test "link_existing_account handles missing account gracefully" do
    snaptrade_account = snaptrade_accounts(:fidelity_401k)

    assert_no_difference "AccountProvider.count" do
      post link_existing_account_snaptrade_items_url, params: {
        account_id: "nonexistent",
        snaptrade_account_id: snaptrade_account.id,
        snaptrade_item_id: @snaptrade_item.id
      }
    end

    assert_redirected_to settings_providers_path
    assert_match(/not found/i, flash[:alert])
  end

  # --- Connection management ---

  test "delete_orphaned_user refuses a user id that is not orphaned" do
    SnaptradeItem.any_instance.stubs(:orphaned_users).returns([])
    SnaptradeItem.any_instance.expects(:delete_orphaned_user).never

    delete delete_orphaned_user_snaptrade_item_url(@snaptrade_item, user_id: "family_other_1")

    assert_redirected_to settings_providers_path
    assert flash[:alert].present?
  end

  test "delete_orphaned_user releases an orphaned registration" do
    SnaptradeItem.any_instance.stubs(:orphaned_users).returns([ "family_other_1" ])
    SnaptradeItem.any_instance.expects(:delete_orphaned_user).with("family_other_1").returns(true)

    delete delete_orphaned_user_snaptrade_item_url(@snaptrade_item, user_id: "family_other_1")

    assert_redirected_to settings_providers_path
    assert flash[:notice].present?
  end

  # --- setup_accounts throttle-sync fix ---
  #
  # The fix on setup_accounts ensures sync_later is only called when there are no
  # accounts AND the item has never been synced (last_synced_at.blank?).  This
  # prevents the infinite-spinner loop where every page load re-triggered a sync
  # even after SnapTrade already confirmed 0 linked accounts.
  #
  # Three view-state branches we need to cover:
  #   A) No accounts + never synced  → trigger sync, render spinner
  #   B) No accounts + synced once, now idle → skip sync, show "no accounts found"
  #   C) No accounts + synced once, still syncing → show spinner, do NOT re-queue

  test "setup_accounts triggers sync and shows spinner when item has no accounts and has never been synced" do
    # Pre-condition: no snaptrade_accounts and no completed syncs (last_synced_at is nil)
    @snaptrade_item.snaptrade_accounts.destroy_all
    @snaptrade_item.syncs.destroy_all

    assert_difference "Sync.count", 1 do
      get setup_accounts_snaptrade_item_url(@snaptrade_item)
    end

    assert_response :success
    assert_select "#snaptrade-sync-spinner", count: 1, message: "Expected the spinner to be shown on first visit with no accounts"
    assert_select ".no-accounts-found", count: 0, message: "Expected the no-accounts UI to be hidden while syncing"
  end

  test "setup_accounts shows no-accounts-found state after a completed sync returns zero accounts" do
    # Pre-condition: no snaptrade_accounts, but there IS a past completed sync
    @snaptrade_item.snaptrade_accounts.destroy_all
    @snaptrade_item.syncs.destroy_all
    @snaptrade_item.syncs.create!(status: :completed, completed_at: 1.minute.ago)

    # Item is not currently syncing → @syncing is false
    assert_not @snaptrade_item.reload.syncing?, "Item should not be syncing for this test"

    assert_no_difference "Sync.count" do
      get setup_accounts_snaptrade_item_url(@snaptrade_item)
    end

    assert_response :success
    assert_select ".no-accounts-found", count: 1, message: "Expected the no-accounts UI to be shown after a completed sync with zero accounts"
    assert_select "#snaptrade-sync-spinner", count: 0, message: "Expected the spinner to be hidden when there is no active sync"
    assert_select "a[href=?]", connect_snaptrade_item_path(@snaptrade_item, return_to: "setup_accounts", accountable_type: nil), text: /Connect Brokerage/
    assert_no_match oauth_connect_snaptrade_items_path(item_id: @snaptrade_item.id), response.body
  end

  test "setup_accounts does not re-queue a sync when a sync is already in progress" do
    # Pre-condition: no accounts, one past completed sync, + one visible (in-flight) sync
    @snaptrade_item.snaptrade_accounts.destroy_all
    @snaptrade_item.syncs.destroy_all
    @snaptrade_item.syncs.create!(status: :completed, completed_at: 5.minutes.ago)
    @snaptrade_item.syncs.create!(status: :pending, created_at: 1.minute.ago)   # visible/in-flight

    assert @snaptrade_item.reload.syncing?, "Item should be syncing for this test"

    assert_no_difference "Sync.count" do
      get setup_accounts_snaptrade_item_url(@snaptrade_item)
    end

    assert_response :success
    assert_select "#snaptrade-sync-spinner", count: 1, message: "Expected the spinner to be shown while sync is in progress"
    assert_select ".no-accounts-found", count: 0, message: "Expected the no-accounts UI to be hidden while a sync is active"
  end
end
