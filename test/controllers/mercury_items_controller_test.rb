# frozen_string_literal: true

require "test_helper"

class MercuryItemsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
    Rails.cache.clear
    SyncJob.stubs(:perform_later)

    @family = families(:dylan_family)
    @existing_item = mercury_items(:one)
    @second_item = MercuryItem.create!(
      family: @family,
      name: "Business Mercury",
      token: "second_mercury_token",
      base_url: "https://api.mercury.com/api/v1"
    )
  end

  teardown do
    Rails.cache.clear
  end

  test "create adds a new mercury connection without overwriting existing credentials" do
    existing_token = @existing_item.token

    assert_difference "MercuryItem.count", 1 do
      post mercury_items_url, params: {
        mercury_item: {
          name: "Joint Mercury",
          token: "joint_mercury_token",
          base_url: "https://api.mercury.com/api/v1"
        }
      }
    end

    assert_redirected_to accounts_path
    assert_equal existing_token, @existing_item.reload.token
    assert_equal "joint_mercury_token", @family.mercury_items.find_by!(name: "Joint Mercury").token
  end

  test "update changes only the selected mercury connection" do
    existing_token = @existing_item.token

    patch mercury_item_url(@second_item), params: {
      mercury_item: {
        name: "Renamed Business Mercury",
        token: "updated_second_token",
        base_url: "https://api-sandbox.mercury.com/api/v1"
      }
    }

    assert_redirected_to accounts_path
    assert_equal existing_token, @existing_item.reload.token
    assert_equal "Renamed Business Mercury", @second_item.reload.name
    assert_equal "updated_second_token", @second_item.token
    assert_equal "https://api-sandbox.mercury.com/api/v1", @second_item.base_url
  end

  test "blank token update preserves the selected mercury token" do
    original_token = @second_item.token

    patch mercury_item_url(@second_item), params: {
      mercury_item: {
        name: "Renamed Business Mercury",
        token: "",
        base_url: "https://api.mercury.com/api/v1"
      }
    }

    assert_redirected_to accounts_path
    assert_equal "Renamed Business Mercury", @second_item.reload.name
    assert_equal original_token, @second_item.token
  end

  test "update expires selected mercury account cache when credentials change" do
    Rails.cache.expects(:delete).with(mercury_cache_key(@existing_item)).never
    Rails.cache.expects(:delete).with(mercury_cache_key(@second_item)).once

    patch mercury_item_url(@second_item), params: {
      mercury_item: {
        name: "Renamed Business Mercury",
        token: "updated_second_token",
        base_url: "https://api-sandbox.mercury.com/api/v1"
      }
    }

    assert_redirected_to accounts_path
  end

  test "update does not expire selected mercury account cache for name-only changes" do
    Rails.cache.expects(:delete).never

    patch mercury_item_url(@second_item), params: {
      mercury_item: {
        name: "Renamed Business Mercury"
      }
    }

    assert_redirected_to accounts_path
    assert_equal "Renamed Business Mercury", @second_item.reload.name
  end

  test "preload accounts uses selected mercury item cache key" do
    Rails.cache.expects(:read).with(mercury_cache_key(@second_item)).returns(nil)
    Rails.cache.expects(:write).with(mercury_cache_key(@second_item), mercury_accounts_payload, expires_in: 5.minutes)

    provider = mock("mercury_provider")
    provider.expects(:get_accounts).returns(accounts: mercury_accounts_payload)
    Provider::Mercury.expects(:new)
      .with(@second_item.token, base_url: @second_item.effective_base_url)
      .returns(provider)

    get preload_accounts_mercury_items_url, params: { mercury_item_id: @second_item.id }, as: :json

    assert_response :success
    response = JSON.parse(@response.body)
    assert_equal true, response["success"]
    assert_equal true, response["has_accounts"]
  end

  test "select accounts requires an explicit connection when multiple mercury items exist" do
    get select_accounts_mercury_items_url, params: { accountable_type: "Depository" }

    assert_redirected_to settings_providers_path
    assert_equal "Choose a Mercury connection in Provider Settings.", flash[:alert]
  end

  test "select accounts renders the selected mercury item id" do
    Rails.cache.expects(:read).with(mercury_cache_key(@second_item)).returns(nil)
    Rails.cache.expects(:write).with(mercury_cache_key(@second_item), mercury_accounts_payload, expires_in: 5.minutes)

    provider = mock("mercury_provider")
    provider.expects(:get_accounts).returns(accounts: mercury_accounts_payload)
    Provider::Mercury.expects(:new)
      .with(@second_item.token, base_url: @second_item.effective_base_url)
      .returns(provider)

    get select_accounts_mercury_items_url, params: {
      mercury_item_id: @second_item.id,
      accountable_type: "Depository"
    }

    assert_response :success
    assert_includes @response.body, %(name="mercury_item_id")
    assert_includes @response.body, %(value="#{@second_item.id}")
  end

  test "select existing account renders the selected mercury item id" do
    account = @family.accounts.create!(
      name: "Manual Checking",
      balance: 0,
      currency: "USD",
      accountable: Depository.new
    )

    Rails.cache.expects(:read).with(mercury_cache_key(@second_item)).returns(nil)
    Rails.cache.expects(:write).with(mercury_cache_key(@second_item), mercury_accounts_payload, expires_in: 5.minutes)

    provider = mock("mercury_provider")
    provider.expects(:get_accounts).returns(accounts: mercury_accounts_payload)
    Provider::Mercury.expects(:new)
      .with(@second_item.token, base_url: @second_item.effective_base_url)
      .returns(provider)

    get select_existing_account_mercury_items_url, params: {
      mercury_item_id: @second_item.id,
      account_id: account.id
    }

    assert_response :success
    assert_includes @response.body, %(name="mercury_item_id")
    assert_includes @response.body, %(value="#{@second_item.id}")
  end

  test "link accounts uses selected mercury item and allows duplicate upstream ids across items" do
    @existing_item.mercury_accounts.create!(
      account_id: "shared_mercury_account",
      name: "Shared Checking",
      currency: "USD",
      current_balance: 1000
    )

    provider = mock("mercury_provider")
    provider.expects(:get_accounts).returns(accounts: mercury_accounts_payload)
    Provider::Mercury.expects(:new)
      .with(@second_item.token, base_url: @second_item.effective_base_url)
      .returns(provider)

    assert_difference -> { @second_item.mercury_accounts.where(account_id: "shared_mercury_account").count }, 1 do
      assert_difference "AccountProvider.count", 1 do
        post link_accounts_mercury_items_url, params: {
          mercury_item_id: @second_item.id,
          account_ids: [ "shared_mercury_account" ],
          accountable_type: "Depository"
        }
      end
    end

    assert_redirected_to accounts_path
    assert_equal 1, @existing_item.mercury_accounts.where(account_id: "shared_mercury_account").count
  end

  test "link accounts does not silently use the first connection when multiple items exist" do
    assert_no_difference "MercuryAccount.count" do
      assert_no_difference "Account.count" do
        post link_accounts_mercury_items_url, params: {
          account_ids: [ "shared_mercury_account" ],
          accountable_type: "Depository"
        }
      end
    end

    assert_redirected_to settings_providers_path
    assert_equal "Choose a Mercury connection before linking accounts.", flash[:alert]
  end

  test "link existing account does not silently use the first connection when multiple items exist" do
    account = @family.accounts.create!(
      name: "Manual Checking",
      balance: 0,
      currency: "USD",
      accountable: Depository.new
    )

    assert_no_difference "MercuryAccount.count" do
      assert_no_difference "AccountProvider.count" do
        post link_existing_account_mercury_items_url, params: {
          account_id: account.id,
          mercury_account_id: "shared_mercury_account"
        }
      end
    end

    assert_redirected_to settings_providers_path
    assert_equal "Choose a Mercury connection before linking accounts.", flash[:alert]
  end

  test "sync only queues a sync for the selected mercury item" do
    assert_difference -> { Sync.where(syncable: @second_item).count }, 1 do
      assert_no_difference -> { Sync.where(syncable: @existing_item).count } do
        post sync_mercury_item_url(@second_item)
      end
    end

    assert_response :redirect
  end

  private

    def mercury_accounts_payload
      [
        {
          id: "shared_mercury_account",
          nickname: "Shared Checking",
          name: "Shared Checking",
          status: "active",
          type: "checking",
          currentBalance: 1000
        }
      ]
    end

    def mercury_cache_key(mercury_item)
      "mercury_accounts_#{@family.id}_#{mercury_item.id}"
    end
end
