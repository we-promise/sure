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

  test "oauth_authorize stores state and verifier in session and redirects to SnapTrade" do
    Rails.configuration.x.snaptrade.oauth_client_id = "client-id"
    Rails.configuration.x.snaptrade.oauth_client_secret = "client-secret"

    get oauth_authorize_snaptrade_items_url

    assert_response :redirect
    redirect = URI.parse(response.location)
    assert_equal "dashboard.snaptrade.com", redirect.host
    params = Rack::Utils.parse_query(redirect.query)
    oauth_session = session[:snaptrade_oauth]
    assert_equal oauth_session["state"], params["state"]
    assert_equal "S256", params["code_challenge_method"]
    assert oauth_session["code_verifier"].present?
    assert oauth_session["item_id"].present?
  ensure
    Rails.configuration.x.snaptrade.oauth_client_id = nil
    Rails.configuration.x.snaptrade.oauth_client_secret = nil
  end

  test "oauth_authorize redirects to settings when OAuth is not configured" do
    Rails.configuration.x.snaptrade.oauth_client_id = nil
    Rails.configuration.x.snaptrade.oauth_client_secret = nil

    get oauth_authorize_snaptrade_items_url
    assert_redirected_to settings_providers_path
  end

  test "oauth_callback rejects state mismatch without exchanging the code" do
    Provider::Snaptrade.expects(:exchange_code).never

    Rails.configuration.x.snaptrade.oauth_client_id = "client-id"
    Rails.configuration.x.snaptrade.oauth_client_secret = "client-secret"
    get oauth_authorize_snaptrade_items_url

    get oauth_callback_snaptrade_items_url(code: "c0de", state: "wrong-state")

    assert_redirected_to settings_providers_path
    assert flash[:alert].present?
  ensure
    Rails.configuration.x.snaptrade.oauth_client_id = nil
    Rails.configuration.x.snaptrade.oauth_client_secret = nil
  end

  test "oauth_callback handles access_denied" do
    get oauth_callback_snaptrade_items_url(error: "access_denied", state: "whatever")
    assert_redirected_to settings_providers_path
    assert flash[:alert].present?
  end

  test "oauth_callback fails when code param is missing" do
    Provider::Snaptrade.expects(:exchange_code).never

    Rails.configuration.x.snaptrade.oauth_client_id = "client-id"
    Rails.configuration.x.snaptrade.oauth_client_secret = "client-secret"
    get oauth_authorize_snaptrade_items_url
    oauth_session = session[:snaptrade_oauth]

    get oauth_callback_snaptrade_items_url(state: oauth_session["state"])

    assert_redirected_to settings_providers_path
    assert_equal "Unable to complete SnapTrade authorization. Please try again.", flash[:alert]
    assert_nil session[:snaptrade_oauth]
  ensure
    Rails.configuration.x.snaptrade.oauth_client_id = nil
    Rails.configuration.x.snaptrade.oauth_client_secret = nil
  end

  test "oauth_callback handles exchange failures without applying tokens" do
    Rails.configuration.x.snaptrade.oauth_client_id = "client-id"
    Rails.configuration.x.snaptrade.oauth_client_secret = "client-secret"
    get oauth_authorize_snaptrade_items_url
    oauth_session = session[:snaptrade_oauth]
    item = SnaptradeItem.find(oauth_session["item_id"])
    original_token = item.oauth_access_token

    Provider::Snaptrade.expects(:exchange_code)
      .with(code: "c0de", redirect_uri: oauth_callback_snaptrade_items_url, code_verifier: oauth_session["code_verifier"])
      .raises(Provider::Snaptrade::Error.new("upstream exchange failed"))

    get oauth_callback_snaptrade_items_url(code: "c0de", state: oauth_session["state"])

    assert_redirected_to settings_providers_path
    assert_equal "Unable to complete SnapTrade authorization. Please try again.", flash[:alert]
    assert_nil session[:snaptrade_oauth]
    assert_equal original_token, item.reload.oauth_access_token
  ensure
    Rails.configuration.x.snaptrade.oauth_client_id = nil
    Rails.configuration.x.snaptrade.oauth_client_secret = nil
  end

  test "oauth_callback exchanges code, stores tokens, queues sync, and resumes setup" do
    Rails.configuration.x.snaptrade.oauth_client_id = "client-id"
    Rails.configuration.x.snaptrade.oauth_client_secret = "client-secret"
    get oauth_authorize_snaptrade_items_url(return_to: "setup_accounts")
    oauth_session = session[:snaptrade_oauth]
    item = SnaptradeItem.find(oauth_session["item_id"])

    Provider::Snaptrade.expects(:exchange_code)
      .with(code: "c0de", redirect_uri: oauth_callback_snaptrade_items_url, code_verifier: oauth_session["code_verifier"])
      .returns({ "access_token" => "at", "refresh_token" => "rt", "expires_in" => 900 })

    get oauth_callback_snaptrade_items_url(code: "c0de", state: oauth_session["state"])

    assert_redirected_to setup_accounts_snaptrade_item_path(item, accountable_type: nil)
    assert_equal "at", item.reload.oauth_access_token
    assert_nil session[:snaptrade_oauth]
  ensure
    Rails.configuration.x.snaptrade.oauth_client_id = nil
    Rails.configuration.x.snaptrade.oauth_client_secret = nil
  end

  test "select_accounts redirects unregistered users into connect flow" do
    sign_out
    sign_in @user = users(:empty)
    snaptrade_item = snaptrade_items(:unauthorized_item)

    get select_accounts_snaptrade_items_url, params: { accountable_type: "Investment", return_to: "setup_accounts" }

    assert_redirected_to oauth_authorize_snaptrade_items_path(
      item_id: snaptrade_item.id,
      accountable_type: "Investment",
      return_to: "setup_accounts"
    )
  end

  test "select_accounts redirects registered users to setup flow" do
    get select_accounts_snaptrade_items_url, params: { accountable_type: "Investment", return_to: "/accounts" }

    assert_redirected_to setup_accounts_snaptrade_item_path(@snaptrade_item, accountable_type: "Investment", return_to: "/accounts")
  end

  test "preload_accounts redirects unregistered users into connect flow" do
    sign_out
    sign_in @user = users(:empty)
    assert_no_difference "Sync.count" do
      get preload_accounts_snaptrade_items_url
    end

    assert_redirected_to oauth_authorize_snaptrade_items_path(item_id: snaptrade_items(:unauthorized_item).id)
  end

  test "preload_accounts redirects registered users to setup flow and queues sync" do
    assert_difference "Sync.count", 1 do
      get preload_accounts_snaptrade_items_url
    end

    assert_redirected_to setup_accounts_snaptrade_item_path(@snaptrade_item)
  end

  test "entry routing prefers a registered active item over a pending one" do
    pending_item = @user.family.snaptrade_items.create!(
      name: "Pending Registration",
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

    assert_not pending_item.oauth_configured?
  end

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

  test "select_existing_account prefers registered active item over pending one" do
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
    assert_no_match oauth_authorize_snaptrade_items_path(item_id: @snaptrade_item.id), response.body
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
