# frozen_string_literal: true

require "test_helper"

class CoinspotItemsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
    SyncJob.stubs(:perform_later)

    @family = families(:dylan_family)
    @existing_item = coinspot_items(:one)
    coinspot_items(:requires_update).update!(scheduled_for_deletion: true)
    @second_item = CoinspotItem.create!(
      family: @family,
      name: "Business CoinSpot",
      api_key: "second_coinspot_key",
      api_secret: "second_coinspot_secret"
    )
  end

  test "create adds a new coinspot connection without overwriting existing credentials" do
    existing_key = @existing_item.api_key
    existing_secret = @existing_item.api_secret

    assert_difference "CoinspotItem.count", 1 do
      post coinspot_items_url, params: {
        coinspot_item: {
          name: "Joint CoinSpot",
          api_key: "joint_coinspot_key",
          api_secret: "joint_coinspot_secret"
        }
      }
    end

    assert_redirected_to settings_providers_path
    assert_equal existing_key, @existing_item.reload.api_key
    assert_equal existing_secret, @existing_item.api_secret
    assert_equal "joint_coinspot_key", @family.coinspot_items.find_by!(name: "Joint CoinSpot").api_key
  end

  test "update changes only the selected coinspot connection" do
    existing_key = @existing_item.api_key

    patch coinspot_item_url(@second_item), params: {
      coinspot_item: {
        name: "Renamed Business CoinSpot",
        api_key: "updated_second_key",
        api_secret: "updated_second_secret"
      }
    }

    assert_redirected_to settings_providers_path
    assert_equal existing_key, @existing_item.reload.api_key
    assert_equal "Renamed Business CoinSpot", @second_item.reload.name
    assert_equal "updated_second_key", @second_item.api_key
    assert_equal "updated_second_secret", @second_item.api_secret
  end

  test "blank secret update preserves the selected coinspot credentials" do
    original_key = @second_item.api_key
    original_secret = @second_item.api_secret

    patch coinspot_item_url(@second_item), params: {
      coinspot_item: {
        name: "Renamed Business CoinSpot",
        api_key: "",
        api_secret: ""
      }
    }

    assert_redirected_to settings_providers_path
    assert_equal "Renamed Business CoinSpot", @second_item.reload.name
    assert_equal original_key, @second_item.api_key
    assert_equal original_secret, @second_item.api_secret
  end

  test "create rejects whitespace-only credentials" do
    assert_no_difference "CoinspotItem.count" do
      post coinspot_items_url, params: {
        coinspot_item: {
          name: "Blank CoinSpot",
          api_key: "   ",
          api_secret: "\n"
        }
      }
    end

    assert_redirected_to settings_providers_path
    assert_match(/API key can't be blank/i, flash[:alert])
  end

  test "select accounts requires an explicit connection when multiple coinspot items exist" do
    get select_accounts_coinspot_items_url, params: { accountable_type: "Crypto" }

    assert_redirected_to settings_providers_path
    assert_equal "Choose a CoinSpot connection in Provider Settings.", flash[:alert]
  end

  test "select accounts targets selected coinspot item" do
    get select_accounts_coinspot_items_url, params: {
      coinspot_item_id: @second_item.id,
      accountable_type: "Crypto"
    }

    assert_redirected_to setup_accounts_coinspot_item_path(@second_item, return_to: nil)
  end

  test "select accounts rejects protocol-relative return paths" do
    get select_accounts_coinspot_items_url, params: {
      coinspot_item_id: @second_item.id,
      accountable_type: "Crypto",
      return_to: "//evil.example/accounts"
    }

    assert_redirected_to setup_accounts_coinspot_item_path(@second_item, return_to: nil)
  end

  test "sync only queues a sync for the selected coinspot item" do
    assert_difference -> { Sync.where(syncable: @second_item).count }, 1 do
      assert_no_difference -> { Sync.where(syncable: @existing_item).count } do
        post sync_coinspot_item_url(@second_item)
      end
    end

    assert_response :redirect
  end

  test "setup accounts creates crypto exchange account for selected item only" do
    first_account = coinspot_accounts(:one)
    second_account = @second_item.coinspot_accounts.create!(
      name: "Second CoinSpot",
      account_id: "combined",
      account_type: "combined",
      currency: "AUD",
      current_balance: 1000
    )
    CoinspotAccount::Processor.any_instance.stubs(:process).returns(nil)

    assert_difference "Account.count", 1 do
      post complete_account_setup_coinspot_item_url(@second_item), params: {
        selected_accounts: [ second_account.id ]
      }
    end

    assert_redirected_to accounts_path
    assert_nil first_account.reload.current_account
    assert_equal "Crypto", second_account.reload.current_account.accountable_type
    assert_equal "exchange", second_account.current_account.accountable.subtype
  end

  test "link existing account links manual crypto exchange account to selected coinspot account" do
    manual_account = manual_crypto_exchange_account
    coinspot_account = @second_item.coinspot_accounts.create!(
      name: "CoinSpot",
      account_id: "combined",
      account_type: "combined",
      currency: "AUD",
      current_balance: 1000
    )

    assert_difference "AccountProvider.count", 1 do
      post link_existing_account_coinspot_items_url, params: {
        coinspot_item_id: @second_item.id,
        account_id: manual_account.id,
        coinspot_account_id: coinspot_account.id
      }
    end

    assert_redirected_to accounts_path
    assert_equal manual_account, coinspot_account.reload.current_account
  end

  test "link existing account requires explicit connection when multiple items exist" do
    account = manual_crypto_exchange_account

    assert_no_difference "AccountProvider.count" do
      post link_existing_account_coinspot_items_url, params: {
        account_id: account.id,
        coinspot_account_id: "combined"
      }
    end

    assert_redirected_to settings_providers_path
    assert_equal "Choose a CoinSpot connection before linking accounts.", flash[:alert]
  end

  test "link existing account rejects non crypto accounts" do
    account = @family.accounts.create!(
      name: "Manual Checking",
      balance: 0,
      currency: "AUD",
      accountable: Depository.new
    )
    coinspot_account = @second_item.coinspot_accounts.create!(name: "CoinSpot", account_id: "combined", account_type: "combined", currency: "AUD")

    assert_no_difference "AccountProvider.count" do
      post link_existing_account_coinspot_items_url, params: {
        coinspot_item_id: @second_item.id,
        account_id: account.id,
        coinspot_account_id: coinspot_account.id
      }
    end

    assert_redirected_to account_path(account)
  end

  test "link existing account rejects accounts with existing provider links" do
    account = manual_crypto_exchange_account
    linked_coinspot_account = coinspot_accounts(:one)
    AccountProvider.create!(account: account, provider: linked_coinspot_account)
    coinspot_account = @second_item.coinspot_accounts.create!(name: "CoinSpot", account_id: "combined", account_type: "combined", currency: "AUD")

    assert_no_difference "AccountProvider.count" do
      post link_existing_account_coinspot_items_url, params: {
        coinspot_item_id: @second_item.id,
        account_id: account.id,
        coinspot_account_id: coinspot_account.id
      }
    end

    assert_redirected_to account_path(account)
  end

  test "link existing account rejects coinspot accounts already linked elsewhere" do
    linked_account = manual_crypto_exchange_account
    available_account = manual_crypto_exchange_account
    coinspot_account = @second_item.coinspot_accounts.create!(name: "CoinSpot", account_id: "combined", account_type: "combined", currency: "AUD")
    AccountProvider.create!(account: linked_account, provider: coinspot_account)

    assert_no_difference "AccountProvider.count" do
      post link_existing_account_coinspot_items_url, params: {
        coinspot_item_id: @second_item.id,
        account_id: available_account.id,
        coinspot_account_id: coinspot_account.id
      }
    end

    assert_redirected_to account_path(available_account)
  end

  test "select existing account renders selected coinspot item id" do
    account = manual_crypto_exchange_account
    @second_item.coinspot_accounts.create!(name: "CoinSpot", account_id: "combined", account_type: "combined", currency: "AUD")

    get select_existing_account_coinspot_items_url, params: {
      coinspot_item_id: @second_item.id,
      account_id: account.id
    }

    assert_response :success
    assert_includes @response.body, %(name="coinspot_item_id")
    assert_includes @response.body, %(value="#{@second_item.id}")
  end

  test "cannot access another family's coinspot item" do
    other_item = CoinspotItem.create!(
      family: families(:empty),
      name: "Other CoinSpot",
      api_key: "other_key",
      api_secret: "other_secret"
    )

    get setup_accounts_coinspot_item_url(other_item)

    assert_response :not_found
  end

  test "complete account setup respects return_to parameter" do
    second_account = @second_item.coinspot_accounts.create!(
      name: "CoinSpot",
      account_id: "combined",
      account_type: "combined",
      currency: "AUD",
      current_balance: 1000
    )
    CoinspotAccount::Processor.any_instance.stubs(:process).returns(nil)

    post complete_account_setup_coinspot_item_url(@second_item), params: {
      selected_accounts: [ second_account.id ],
      return_to: "/accounts"
    }

    assert_redirected_to accounts_path
  end

  test "complete account setup rejects malicious return_to paths" do
    second_account = @second_item.coinspot_accounts.create!(
      name: "CoinSpot",
      account_id: "combined",
      account_type: "combined",
      currency: "AUD",
      current_balance: 1000
    )
    CoinspotAccount::Processor.any_instance.stubs(:process).returns(nil)

    post complete_account_setup_coinspot_item_url(@second_item), params: {
      selected_accounts: [ second_account.id ],
      return_to: "//evil.example/accounts"
    }

    assert_redirected_to accounts_path
  end

  test "complete account setup rejects backslash return_to paths" do
    second_account = @second_item.coinspot_accounts.create!(
      name: "CoinSpot",
      account_id: "combined",
      account_type: "combined",
      currency: "AUD",
      current_balance: 1000
    )
    CoinspotAccount::Processor.any_instance.stubs(:process).returns(nil)

    post complete_account_setup_coinspot_item_url(@second_item), params: {
      selected_accounts: [ second_account.id ],
      return_to: "\\evil"
    }

    assert_redirected_to accounts_path
  end

  test "complete account setup rejects encoded separator return_to paths" do
    second_account = @second_item.coinspot_accounts.create!(
      name: "CoinSpot",
      account_id: "combined",
      account_type: "combined",
      currency: "AUD",
      current_balance: 1000
    )
    CoinspotAccount::Processor.any_instance.stubs(:process).returns(nil)

    post complete_account_setup_coinspot_item_url(@second_item), params: {
      selected_accounts: [ second_account.id ],
      return_to: "/%2Fevil"
    }

    assert_redirected_to accounts_path
  end

  private

    def manual_crypto_exchange_account
      @family.accounts.create!(
        name: "Manual Crypto",
        balance: 0,
        currency: "AUD",
        accountable: Crypto.create!(subtype: "exchange")
      )
    end
end
