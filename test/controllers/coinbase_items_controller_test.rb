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

  test "should sync coinbase item" do
    post sync_coinbase_item_url(@coinbase_item)
    assert_response :redirect
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
end
