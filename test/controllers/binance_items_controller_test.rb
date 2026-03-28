require "test_helper"

class BinanceItemsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    sign_in users(:family_admin)
    @family = families(:dylan_family)
    @binance_item = BinanceItem.create!(
      family: @family,
      name: "Test Binance",
      api_key: "test_key",
      api_secret: "test_secret"
    )
  end

  test "should destroy binance item" do
    assert_difference("BinanceItem.count", 0) do
      delete binance_item_url(@binance_item)
    end

    assert_redirected_to settings_providers_path
    @binance_item.reload
    assert @binance_item.scheduled_for_deletion?
  end

  test "should sync binance item" do
    post sync_binance_item_url(@binance_item)
    assert_response :redirect
  end

  test "should show setup_accounts page" do
    get setup_accounts_binance_item_url(@binance_item)
    assert_response :success
  end

  test "complete_account_setup creates accounts for selected binance_accounts" do
    binance_account = @binance_item.binance_accounts.create!(
      name: "Binance Spot",
      account_id: "uid_123",
      currency: "USD",
      current_balance: 50_000
    )

    BinanceAccount::Processor.any_instance.stubs(:process).returns({})

    assert_difference "Account.count", 1 do
      post complete_account_setup_binance_item_url(@binance_item), params: {
        selected_accounts: [ binance_account.id ]
      }
    end

    assert_response :redirect
    binance_account.reload
    assert_not_nil binance_account.current_account
    assert_equal "Crypto", binance_account.current_account.accountable_type
  end

  test "complete_account_setup with no selection shows message" do
    @binance_item.binance_accounts.create!(
      name: "Binance Spot",
      account_id: "uid_123",
      currency: "USD",
      current_balance: 10_000
    )

    assert_no_difference "Account.count" do
      post complete_account_setup_binance_item_url(@binance_item), params: {
        selected_accounts: []
      }
    end

    assert_response :redirect
  end

  test "complete_account_setup skips already linked accounts" do
    binance_account = @binance_item.binance_accounts.create!(
      name: "Binance Spot",
      account_id: "uid_123",
      currency: "USD",
      current_balance: 10_000
    )

    account = Account.create!(
      family: @family,
      name: "Existing Binance",
      balance: 10_000,
      currency: "USD",
      accountable: Crypto.create!(subtype: "exchange")
    )
    AccountProvider.create!(account: account, provider: binance_account)

    assert_no_difference "Account.count" do
      post complete_account_setup_binance_item_url(@binance_item), params: {
        selected_accounts: [ binance_account.id ]
      }
    end
  end

  test "cannot access other family's binance_item" do
    other_item = BinanceItem.create!(
      family: families(:empty),
      name: "Other Binance",
      api_key: "other_key",
      api_secret: "other_secret"
    )

    get setup_accounts_binance_item_url(other_item)
    assert_response :not_found
  end

  test "link_existing_account links manual account to binance_account" do
    manual_account = Account.create!(
      family: @family,
      name: "Manual Crypto",
      balance: 0,
      currency: "USD",
      accountable: Crypto.create!(subtype: "exchange")
    )

    binance_account = @binance_item.binance_accounts.create!(
      name: "Binance Spot",
      account_id: "uid_123",
      currency: "USD",
      current_balance: 10_000
    )

    assert_difference "AccountProvider.count", 1 do
      post link_existing_account_binance_items_url, params: {
        account_id: manual_account.id,
        binance_account_id: binance_account.id
      }
    end

    binance_account.reload
    assert_equal manual_account, binance_account.current_account
  end

  test "link_existing_account rejects account with existing provider" do
    linked_account = Account.create!(
      family: @family,
      name: "Already Linked",
      balance: 0,
      currency: "USD",
      accountable: Crypto.create!(subtype: "exchange")
    )

    other_binance_account = @binance_item.binance_accounts.create!(
      name: "Other Spot",
      account_id: "uid_999",
      currency: "USD",
      current_balance: 5_000
    )
    AccountProvider.create!(account: linked_account, provider: other_binance_account)

    binance_account = @binance_item.binance_accounts.create!(
      name: "Binance Spot",
      account_id: "uid_123",
      currency: "USD",
      current_balance: 10_000
    )

    assert_no_difference "AccountProvider.count" do
      post link_existing_account_binance_items_url, params: {
        account_id: linked_account.id,
        binance_account_id: binance_account.id
      }
    end
  end
end
