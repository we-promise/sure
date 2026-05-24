# frozen_string_literal: true

require "test_helper"

class KrakenItemsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
    SyncJob.stubs(:perform_later)

    @family = families(:dylan_family)
    @existing_item = kraken_items(:one)
    kraken_items(:requires_update).update!(scheduled_for_deletion: true)
    @second_item = KrakenItem.create!(
      family: @family,
      name: "Business Kraken",
      api_key: "second_kraken_key",
      api_secret: "second_kraken_secret"
    )
  end

  test "create adds a new kraken connection without overwriting existing credentials" do
    existing_key = @existing_item.api_key
    existing_secret = @existing_item.api_secret

    assert_difference "KrakenItem.count", 1 do
      post kraken_items_url, params: {
        kraken_item: {
          name: "Joint Kraken",
          api_key: "joint_kraken_key",
          api_secret: "joint_kraken_secret"
        }
      }
    end

    assert_redirected_to settings_providers_path
    assert_equal existing_key, @existing_item.reload.api_key
    assert_equal existing_secret, @existing_item.api_secret
    assert_equal "joint_kraken_key", @family.kraken_items.find_by!(name: "Joint Kraken").api_key
  end

  test "update changes only the selected kraken connection" do
    existing_key = @existing_item.api_key

    patch kraken_item_url(@second_item), params: {
      kraken_item: {
        name: "Renamed Business Kraken",
        api_key: "updated_second_key",
        api_secret: "updated_second_secret"
      }
    }

    assert_redirected_to settings_providers_path
    assert_equal existing_key, @existing_item.reload.api_key
    assert_equal "Renamed Business Kraken", @second_item.reload.name
    assert_equal "updated_second_key", @second_item.api_key
    assert_equal "updated_second_secret", @second_item.api_secret
  end

  test "blank secret update preserves the selected kraken credentials" do
    original_key = @second_item.api_key
    original_secret = @second_item.api_secret

    patch kraken_item_url(@second_item), params: {
      kraken_item: {
        name: "Renamed Business Kraken",
        api_key: "",
        api_secret: ""
      }
    }

    assert_redirected_to settings_providers_path
    assert_equal "Renamed Business Kraken", @second_item.reload.name
    assert_equal original_key, @second_item.api_key
    assert_equal original_secret, @second_item.api_secret
  end

  test "create rejects whitespace-only credentials" do
    assert_no_difference "KrakenItem.count" do
      post kraken_items_url, params: {
        kraken_item: {
          name: "Blank Kraken",
          api_key: "   ",
          api_secret: "\n"
        }
      }
    end

    assert_redirected_to settings_providers_path
    assert_match(/API key can't be blank/i, flash[:alert])
  end

  test "select accounts requires an explicit connection when multiple kraken items exist" do
    get select_accounts_kraken_items_url, params: { accountable_type: "Crypto" }

    assert_redirected_to settings_providers_path
    assert_equal "Choose a Kraken connection in Provider Settings.", flash[:alert]
  end

  test "select accounts targets selected kraken item" do
    get select_accounts_kraken_items_url, params: {
      kraken_item_id: @second_item.id,
      accountable_type: "Crypto"
    }

    assert_redirected_to setup_accounts_kraken_item_path(@second_item, return_to: nil)
  end

  test "select accounts rejects protocol-relative return paths" do
    get select_accounts_kraken_items_url, params: {
      kraken_item_id: @second_item.id,
      accountable_type: "Crypto",
      return_to: "//evil.example/accounts"
    }

    assert_redirected_to setup_accounts_kraken_item_path(@second_item, return_to: nil)
  end

  test "sync only queues a sync for the selected kraken item" do
    assert_difference -> { Sync.where(syncable: @second_item).count }, 1 do
      assert_no_difference -> { Sync.where(syncable: @existing_item).count } do
        post sync_kraken_item_url(@second_item)
      end
    end

    assert_response :redirect
  end

  test "setup accounts creates crypto exchange account for selected item only" do
    first_account = kraken_accounts(:one)
    second_account = @second_item.kraken_accounts.create!(
      name: "Second Kraken",
      account_id: "combined",
      account_type: "combined",
      currency: "USD",
      current_balance: 1000
    )
    KrakenAccount::Processor.any_instance.stubs(:process).returns(nil)

    assert_difference "Account.count", 1 do
      post complete_account_setup_kraken_item_url(@second_item), params: {
        selected_accounts: [ second_account.id ]
      }
    end

    assert_redirected_to accounts_path
    assert_nil first_account.reload.current_account
    assert_equal "Crypto", second_account.reload.current_account.accountable_type
    assert_equal "exchange", second_account.current_account.accountable.subtype
  end

  test "link existing account links manual crypto exchange account to selected kraken account" do
    manual_account = manual_crypto_exchange_account
    kraken_account = @second_item.kraken_accounts.create!(
      name: "Kraken",
      account_id: "combined",
      account_type: "combined",
      currency: "USD",
      current_balance: 1000
    )

    assert_difference "AccountProvider.count", 1 do
      post link_existing_account_kraken_items_url, params: {
        kraken_item_id: @second_item.id,
        account_id: manual_account.id,
        kraken_account_id: kraken_account.id
      }
    end

    assert_redirected_to accounts_path
    assert_equal manual_account, kraken_account.reload.current_account
  end

  test "link existing account requires explicit connection when multiple items exist" do
    account = manual_crypto_exchange_account

    assert_no_difference "AccountProvider.count" do
      post link_existing_account_kraken_items_url, params: {
        account_id: account.id,
        kraken_account_id: "combined"
      }
    end

    assert_redirected_to settings_providers_path
    assert_equal "Choose a Kraken connection before linking accounts.", flash[:alert]
  end

  test "link existing account rejects non crypto accounts" do
    account = @family.accounts.create!(
      name: "Manual Checking",
      balance: 0,
      currency: "USD",
      accountable: Depository.new
    )
    kraken_account = @second_item.kraken_accounts.create!(name: "Kraken", account_id: "combined", account_type: "combined", currency: "USD")

    assert_no_difference "AccountProvider.count" do
      post link_existing_account_kraken_items_url, params: {
        kraken_item_id: @second_item.id,
        account_id: account.id,
        kraken_account_id: kraken_account.id
      }
    end

    assert_redirected_to account_path(account)
  end

  test "link existing account rejects accounts with existing provider links" do
    account = manual_crypto_exchange_account
    linked_kraken_account = kraken_accounts(:one)
    AccountProvider.create!(account: account, provider: linked_kraken_account)
    kraken_account = @second_item.kraken_accounts.create!(name: "Kraken", account_id: "combined", account_type: "combined", currency: "USD")

    assert_no_difference "AccountProvider.count" do
      post link_existing_account_kraken_items_url, params: {
        kraken_item_id: @second_item.id,
        account_id: account.id,
        kraken_account_id: kraken_account.id
      }
    end

    assert_redirected_to account_path(account)
  end

  test "link existing account rejects kraken accounts already linked elsewhere" do
    linked_account = manual_crypto_exchange_account
    available_account = manual_crypto_exchange_account
    kraken_account = @second_item.kraken_accounts.create!(name: "Kraken", account_id: "combined", account_type: "combined", currency: "USD")
    AccountProvider.create!(account: linked_account, provider: kraken_account)

    assert_no_difference "AccountProvider.count" do
      post link_existing_account_kraken_items_url, params: {
        kraken_item_id: @second_item.id,
        account_id: available_account.id,
        kraken_account_id: kraken_account.id
      }
    end

    assert_redirected_to account_path(available_account)
  end

  test "select existing account renders selected kraken item id" do
    account = manual_crypto_exchange_account
    @second_item.kraken_accounts.create!(name: "Kraken", account_id: "combined", account_type: "combined", currency: "USD")

    get select_existing_account_kraken_items_url, params: {
      kraken_item_id: @second_item.id,
      account_id: account.id
    }

    assert_response :success
    assert_includes @response.body, %(name="kraken_item_id")
    assert_includes @response.body, %(value="#{@second_item.id}")
  end

  test "cannot access another family's kraken item" do
    other_item = KrakenItem.create!(
      family: families(:empty),
      name: "Other Kraken",
      api_key: "other_key",
      api_secret: "other_secret"
    )

    get setup_accounts_kraken_item_url(other_item)

    assert_response :not_found
  end

  private

    def manual_crypto_exchange_account
      @family.accounts.create!(
        name: "Manual Crypto",
        balance: 0,
        currency: "USD",
        accountable: Crypto.create!(subtype: "exchange")
      )
    end
end
