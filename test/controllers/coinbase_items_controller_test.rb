require "test_helper"

class CoinbaseItemsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    sign_in users(:family_admin)
    @family = families(:dylan_family)
    @coinbase_item = CoinbaseItem.create!(
      family: @family,
      name: "Test Coinbase",
      api_key: "test_key",
      api_secret: "test_secret"
    )
  end

  test "should destroy coinbase item" do
    assert_difference("CoinbaseItem.count", 0) do # doesn't delete immediately
      delete coinbase_item_url(@coinbase_item)
    end

    assert_redirected_to settings_providers_path
    @coinbase_item.reload
    assert @coinbase_item.scheduled_for_deletion?
  end

  test "invalid create outside a frame redirects to the providers page with a 303" do
    assert_no_difference "CoinbaseItem.count" do
      post coinbase_items_url, params: { coinbase_item: { api_key: "", api_secret: "" } }
    end

    assert_response :see_other
    assert_redirected_to settings_providers_path
    assert_match "can't be blank", flash[:alert]
  end

  test "invalid create from the page shows the error in the panel" do
    post coinbase_items_url,
         params: { coinbase_item: { api_key: "", api_secret: "" } },
         as: :turbo_stream

    assert_turbo_stream status: :unprocessable_entity, action: "replace", target: "coinbase-providers-panel"
    assert_includes response.body, ERB::Util.html_escape("can't be blank")
  end

  test "invalid update outside a frame redirects to the providers page with a 303" do
    patch coinbase_item_url(@coinbase_item), params: { coinbase_item: { api_key: "" } }

    assert_response :see_other
    assert_redirected_to settings_providers_path
    assert_match "can't be blank", flash[:alert]
  end

  test "should sync coinbase item" do
    post sync_coinbase_item_url(@coinbase_item)
    assert_response :redirect
  end

  # Redirecting back to Bank sync would collapse the open connection row.
  test "sync from the panel re-renders the panel in place" do
    post sync_coinbase_item_url(@coinbase_item, source: "panel"), as: :turbo_stream

    assert_turbo_stream action: "replace", target: "coinbase-providers-panel"
    assert_includes response.body, I18n.t("settings.providers.sync_provider_in_progress")
    assert @coinbase_item.reload.syncing?
  end

  # Add Account -> Crypto -> Coinbase used to bounce back to Settings even when
  # the connection's sync had already found wallets waiting to be set up.
  test "select_accounts opens the wallet setup of the family's Coinbase connection" do
    get select_accounts_coinbase_items_url

    assert_redirected_to setup_accounts_coinbase_item_path(@coinbase_item)
    assert_response :see_other
  end

  test "select_accounts sends the user to Settings when no connection has credentials" do
    @coinbase_item.update!(scheduled_for_deletion: true)

    get select_accounts_coinbase_items_url

    assert_redirected_to settings_providers_path
    assert_equal I18n.t("coinbase_items.select_accounts.no_credentials_configured"), flash[:alert]
  end

  test "select_accounts leaves the Add Account modal for Settings at the top level" do
    @coinbase_item.update!(scheduled_for_deletion: true)

    get select_accounts_coinbase_items_url, headers: { "Turbo-Frame" => "modal" }

    # A redirect would be followed inside the frame and the flash lost.
    assert_response :success
    assert_select "turbo-frame#modal turbo-stream[action=redirect][target=?]", settings_providers_path
    assert_equal I18n.t("coinbase_items.select_accounts.no_credentials_configured"), flash[:alert]
  end

  test "select_accounts asks which connection when there are several, unless one is named" do
    other_item = CoinbaseItem.create!(family: @family, name: "Second Coinbase", api_key: "key_2", api_secret: "secret_2")

    get select_accounts_coinbase_items_url

    assert_redirected_to settings_providers_path
    assert_equal I18n.t("coinbase_items.select_accounts.select_connection"), flash[:alert]

    get select_accounts_coinbase_items_url(coinbase_item_id: other_item.id)

    assert_redirected_to setup_accounts_coinbase_item_path(other_item)
  end

  test "select_accounts says the named connection is unavailable when another one exists" do
    get select_accounts_coinbase_items_url(coinbase_item_id: SecureRandom.uuid)

    assert_redirected_to settings_providers_path
    assert_equal I18n.t("coinbase_items.select_accounts.connection_unavailable"), flash[:alert]
  end

  test "select_accounts carries a safe return_to into setup and drops an unsafe one" do
    get select_accounts_coinbase_items_url(return_to: "/imports/123/confirm")
    assert_redirected_to setup_accounts_coinbase_item_path(@coinbase_item, return_to: "/imports/123/confirm")

    get select_accounts_coinbase_items_url(return_to: "//evil.example")
    assert_redirected_to setup_accounts_coinbase_item_path(@coinbase_item)
  end

  test "setup_accounts keeps return_to for finishing and cancelling" do
    get setup_accounts_coinbase_item_url(@coinbase_item, return_to: "/imports/123/confirm")

    assert_response :success
    assert_select "input[type=hidden][name=return_to][value=?]", "/imports/123/confirm"
    assert_select "a[href=?]", "/imports/123/confirm", text: I18n.t("coinbase_items.setup_accounts.cancel")
  end

  test "complete_account_setup returns to return_to" do
    post complete_account_setup_coinbase_item_url(@coinbase_item), params: { return_to: "/imports/123/confirm" }

    assert_redirected_to "/imports/123/confirm"
  end

  test "should show setup_accounts page" do
    get setup_accounts_coinbase_item_url(@coinbase_item)
    assert_response :success
  end

  test "complete_account_setup creates accounts for selected coinbase_accounts" do
    coinbase_account = @coinbase_item.coinbase_accounts.create!(
      name: "BTC Wallet",
      account_id: "btc_123",
      currency: "BTC",
      current_balance: 0.5,
      raw_payload: { "native_balance" => { "amount" => "50000", "currency" => "USD" } }
    )

    assert_difference "Account.count", 1 do
      post complete_account_setup_coinbase_item_url(@coinbase_item), params: {
        selected_accounts: [ coinbase_account.id ]
      }
    end

    assert_response :redirect

    # Verify account was created and linked
    coinbase_account.reload
    assert_not_nil coinbase_account.current_account
    assert_equal "Crypto", coinbase_account.current_account.accountable_type
  end

  test "complete_account_setup with no selection shows message" do
    @coinbase_item.coinbase_accounts.create!(
      name: "BTC Wallet",
      account_id: "btc_123",
      currency: "BTC",
      current_balance: 0.5
    )

    assert_no_difference "Account.count" do
      post complete_account_setup_coinbase_item_url(@coinbase_item), params: {
        selected_accounts: []
      }
    end

    assert_response :redirect
  end

  test "complete_account_setup skips already linked accounts" do
    coinbase_account = @coinbase_item.coinbase_accounts.create!(
      name: "BTC Wallet",
      account_id: "btc_123",
      currency: "BTC",
      current_balance: 0.5
    )

    # Pre-link the account
    account = Account.create!(
      family: @family,
      name: "Existing BTC",
      balance: 50000,
      currency: "USD",
      accountable: Crypto.create!(subtype: "exchange")
    )
    AccountProvider.create!(account: account, provider: coinbase_account)

    assert_no_difference "Account.count" do
      post complete_account_setup_coinbase_item_url(@coinbase_item), params: {
        selected_accounts: [ coinbase_account.id ]
      }
    end
  end

  test "cannot access other family's coinbase_item" do
    other_family = families(:empty)
    other_item = CoinbaseItem.create!(
      family: other_family,
      name: "Other Coinbase",
      api_key: "other_test_key",
      api_secret: "other_test_secret"
    )

    get setup_accounts_coinbase_item_url(other_item)
    assert_response :not_found
  end

  test "link_existing_account links manual account to coinbase_account" do
    # Create a manual account (no provider links)
    manual_account = Account.create!(
      family: @family,
      name: "Manual Crypto",
      balance: 0,
      currency: "USD",
      accountable: Crypto.create!(subtype: "exchange")
    )

    # Create a coinbase account
    coinbase_account = @coinbase_item.coinbase_accounts.create!(
      name: "BTC Wallet",
      account_id: "btc_123",
      currency: "BTC",
      current_balance: 0.5
    )

    assert_difference "AccountProvider.count", 1 do
      post link_existing_account_coinbase_items_url, params: {
        account_id: manual_account.id,
        coinbase_account_id: coinbase_account.id
      }
    end

    coinbase_account.reload
    assert_equal manual_account, coinbase_account.current_account
  end

  test "link_existing_account rejects account with existing provider" do
    # Create an account already linked via AccountProvider
    linked_account = Account.create!(
      family: @family,
      name: "Already Linked",
      balance: 0,
      currency: "USD",
      accountable: Crypto.create!(subtype: "exchange")
    )

    # Create an existing provider link (e.g., from another Coinbase account)
    other_coinbase_account = @coinbase_item.coinbase_accounts.create!(
      name: "Other Wallet",
      account_id: "other_123",
      currency: "ETH",
      current_balance: 1.0
    )
    AccountProvider.create!(account: linked_account, provider: other_coinbase_account)

    # Try to link a different coinbase account to the same account
    coinbase_account = @coinbase_item.coinbase_accounts.create!(
      name: "BTC Wallet",
      account_id: "btc_123",
      currency: "BTC",
      current_balance: 0.5
    )

    assert_no_difference "AccountProvider.count" do
      post link_existing_account_coinbase_items_url, params: {
        account_id: linked_account.id,
        coinbase_account_id: coinbase_account.id
      }
    end
  end

  # The orphan cleanup's enqueue runs once the relink transaction commits. If it
  # ran inside that transaction, its error would escape the action's rescue
  # after the relink had committed, and the request would fail.
  test "link_existing_account still succeeds when the orphan's destroy enqueue fails" do
    orphan = Account.create!(
      family: @family,
      name: "Old Crypto",
      balance: 0,
      currency: "USD",
      accountable: Crypto.create!(subtype: "exchange")
    )
    target = Account.create!(
      family: @family,
      name: "Manual Crypto",
      balance: 0,
      currency: "USD",
      accountable: Crypto.create!(subtype: "exchange")
    )
    coinbase_account = @coinbase_item.coinbase_accounts.create!(
      name: "BTC Wallet",
      account_id: "btc_123",
      currency: "BTC",
      current_balance: 0.5
    )
    AccountProvider.create!(account: orphan, provider: coinbase_account)
    DestroyJob.queue_adapter.expects(:enqueue).once.raises(RedisClient::CannotConnectError, "Connection refused")

    post link_existing_account_coinbase_items_url, params: {
      account_id: target.id,
      coinbase_account_id: coinbase_account.id
    }

    assert_redirected_to accounts_path
    assert_equal target, coinbase_account.reload.current_account
    assert_equal "active", orphan.reload.status
  end
end
