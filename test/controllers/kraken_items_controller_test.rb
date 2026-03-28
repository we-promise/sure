require "test_helper"

class KrakenItemsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    sign_in users(:family_admin)
    @family = families(:dylan_family)
    @kraken_item = KrakenItem.create!(
      family: @family,
      name: "Test Kraken",
      api_key: "test_key",
      api_secret: "test_secret"
    )
  end

  test "should destroy kraken item" do
    assert_difference("KrakenItem.count", 0) do
      delete kraken_item_url(@kraken_item)
    end

    assert_redirected_to settings_providers_path
    @kraken_item.reload
    assert @kraken_item.scheduled_for_deletion?
  end

  test "should sync kraken item" do
    post sync_kraken_item_url(@kraken_item)
    assert_response :redirect
  end

  test "should show setup_accounts page" do
    get setup_accounts_kraken_item_url(@kraken_item)
    assert_response :success
  end

  test "complete_account_setup creates accounts for selected kraken_accounts" do
    kraken_account = @kraken_item.kraken_accounts.create!(
      name: "BTC Balance",
      account_id: "BTC",
      currency: "BTC",
      current_balance: 0.5,
      raw_payload: {
        "native_balance" => { "amount" => "50000", "currency" => "USD" }
      }
    )

    assert_difference "Account.count", 1 do
      post complete_account_setup_kraken_item_url(@kraken_item), params: {
        selected_accounts: [ kraken_account.id ]
      }
    end

    assert_response :redirect
    kraken_account.reload
    assert_not_nil kraken_account.current_account
    assert_equal "Crypto", kraken_account.current_account.accountable_type
  end

  test "complete_account_setup with no selection shows message" do
    @kraken_item.kraken_accounts.create!(
      name: "BTC Balance",
      account_id: "BTC",
      currency: "BTC",
      current_balance: 0.5
    )

    assert_no_difference "Account.count" do
      post complete_account_setup_kraken_item_url(@kraken_item), params: {
        selected_accounts: []
      }
    end

    assert_response :redirect
  end

  test "complete_account_setup skips already linked accounts" do
    kraken_account = @kraken_item.kraken_accounts.create!(
      name: "BTC Balance",
      account_id: "BTC",
      currency: "BTC",
      current_balance: 0.5
    )

    account = Account.create!(
      family: @family,
      name: "Existing BTC",
      balance: 50000,
      currency: "USD",
      accountable: Crypto.create!(subtype: "exchange")
    )
    AccountProvider.create!(account: account, provider: kraken_account)

    assert_no_difference "Account.count" do
      post complete_account_setup_kraken_item_url(@kraken_item), params: {
        selected_accounts: [ kraken_account.id ]
      }
    end
  end

  test "cannot access other family's kraken_item" do
    other_family = families(:empty)
    other_item = KrakenItem.create!(
      family: other_family,
      name: "Other Kraken",
      api_key: "other_key",
      api_secret: "other_secret"
    )

    get setup_accounts_kraken_item_url(other_item)
    assert_response :not_found
  end

  test "link_existing_account links manual account to kraken_account" do
    manual_account = Account.create!(
      family: @family,
      name: "Manual Crypto",
      balance: 0,
      currency: "USD",
      accountable: Crypto.create!(subtype: "exchange")
    )

    kraken_account = @kraken_item.kraken_accounts.create!(
      name: "BTC Balance",
      account_id: "BTC",
      currency: "BTC",
      current_balance: 0.5
    )

    assert_difference "AccountProvider.count", 1 do
      post link_existing_account_kraken_items_url, params: {
        account_id: manual_account.id,
        kraken_account_id: kraken_account.id
      }
    end

    kraken_account.reload
    assert_equal manual_account, kraken_account.current_account
  end

  test "link_existing_account rejects account with existing provider" do
    linked_account = Account.create!(
      family: @family,
      name: "Already Linked",
      balance: 0,
      currency: "USD",
      accountable: Crypto.create!(subtype: "exchange")
    )

    other_kraken_account = @kraken_item.kraken_accounts.create!(
      name: "ETH Balance",
      account_id: "ETH",
      currency: "ETH",
      current_balance: 1.0
    )
    AccountProvider.create!(account: linked_account, provider: other_kraken_account)

    kraken_account = @kraken_item.kraken_accounts.create!(
      name: "BTC Balance",
      account_id: "BTC",
      currency: "BTC",
      current_balance: 0.5
    )

    assert_no_difference "AccountProvider.count" do
      post link_existing_account_kraken_items_url, params: {
        account_id: linked_account.id,
        kraken_account_id: kraken_account.id
      }
    end
  end
end
