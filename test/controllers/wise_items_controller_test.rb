# frozen_string_literal: true

require "test_helper"

class WiseItemsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
    SyncJob.stubs(:perform_later)

    @family = families(:dylan_family)
    @wise_item = wise_items(:one)
  end

  # ---------------------------------------------------------------------------
  # create
  # ---------------------------------------------------------------------------

  test "create adds a new wise connection" do
    assert_difference "WiseItem.count", 1 do
      post wise_items_url, params: {
        wise_item: { name: "Business Wise", api_token: "new_token_abc" }
      }
    end

    assert_redirected_to settings_providers_path
    assert_equal "new_token_abc", @family.wise_items.find_by!(name: "Business Wise").api_token
  end

  test "create uses localized default name when submitted name is blank" do
    assert_difference "WiseItem.count", 1 do
      post wise_items_url, params: {
        wise_item: { name: "  ", api_token: "default_name_token" }
      }
    end

    assert_redirected_to settings_providers_path
    assert_equal I18n.t("wise_items.default_name"), @family.wise_items.order(:created_at).last.name
  end

  test "create fails without api_token" do
    assert_no_difference "WiseItem.count" do
      post wise_items_url, params: {
        wise_item: { name: "No Token", api_token: "" }
      }
    end

    assert_redirected_to settings_providers_path
  end

  # ---------------------------------------------------------------------------
  # update
  # ---------------------------------------------------------------------------

  test "update renames item and resets status to good when new token provided" do
    @wise_item.update!(status: :requires_update)

    patch wise_item_url(@wise_item), params: {
      wise_item: { name: "Renamed Wise", api_token: "refreshed_token" }
    }

    @wise_item.reload
    assert_redirected_to settings_providers_path
    assert_equal "Renamed Wise", @wise_item.name
    assert_equal "refreshed_token", @wise_item.api_token
    assert_equal "good", @wise_item.status
  end

  test "update with blank token preserves existing token" do
    original_token = @wise_item.api_token

    patch wise_item_url(@wise_item), params: {
      wise_item: { name: "Renamed Wise", api_token: "" }
    }

    @wise_item.reload
    assert_redirected_to settings_providers_path
    assert_equal "Renamed Wise", @wise_item.name
    assert_equal original_token, @wise_item.api_token
  end

  # ---------------------------------------------------------------------------
  # destroy
  # ---------------------------------------------------------------------------

  test "destroy schedules the item for deletion" do
    delete wise_item_url(@wise_item)

    assert_redirected_to settings_providers_path
    assert @wise_item.reload.scheduled_for_deletion?
  end

  # ---------------------------------------------------------------------------
  # sync
  # ---------------------------------------------------------------------------

  test "sync enqueues a sync job" do
    assert_difference -> { Sync.where(syncable: @wise_item).count }, 1 do
      post sync_wise_item_url(@wise_item)
    end

    assert_response :redirect
  end

  test "sync is a no-op when item is already syncing" do
    @wise_item.syncs.create!(status: :syncing)

    assert_no_difference -> { Sync.where(syncable: @wise_item).count } do
      post sync_wise_item_url(@wise_item)
    end

    assert_response :redirect
  end

  # ---------------------------------------------------------------------------
  # select_accounts / link_accounts
  # ---------------------------------------------------------------------------

  test "select_accounts redirects to setup_accounts when credentials configured" do
    get select_accounts_wise_items_url

    assert_redirected_to setup_accounts_wise_item_url(@wise_item)
  end

  test "select_accounts redirects to settings when credentials not configured" do
    @wise_item.update_column(:api_token, nil)

    get select_accounts_wise_items_url

    assert_redirected_to settings_providers_path
  end

  test "link_accounts creates new accounts for selected wise_accounts" do
    wise_account = @wise_item.wise_accounts.create!(
      name: "CAD Jar",
      currency: "CAD",
      current_balance: 500,
      wise_account_id: "jar-001",
      wise_profile_id: "prof-001"
    )

    assert_difference "Account.count", 1 do
      assert_difference "AccountProvider.count", 1 do
        post link_accounts_wise_items_url, params: {
          selected_account_ids: [ wise_account.id ],
          accountable_type: "Depository"
        }
      end
    end

    assert_redirected_to accounts_path
  end

  test "link_accounts redirects to settings when no credentials configured" do
    @wise_item.update_column(:api_token, nil)

    post link_accounts_wise_items_url, params: {
      selected_account_ids: [ 999 ]
    }

    assert_redirected_to settings_providers_path
  end

  test "link_accounts redirects when no account ids selected" do
    post link_accounts_wise_items_url, params: { selected_account_ids: [] }

    assert_redirected_to select_accounts_wise_items_url
  end

  # ---------------------------------------------------------------------------
  # setup_accounts / complete_account_setup
  # ---------------------------------------------------------------------------

  test "setup_accounts renders unlinked accounts" do
    get setup_accounts_wise_item_url(@wise_item)

    assert_response :success
  end

  test "complete_account_setup creates accounts from config and redirects" do
    wise_account = @wise_item.wise_accounts.create!(
      name: "EUR Jar",
      currency: "EUR",
      current_balance: 200,
      wise_account_id: "jar-eur-001",
      wise_profile_id: "prof-001"
    )

    assert_difference "Account.count", 1 do
      post complete_account_setup_wise_item_url(@wise_item), params: {
        accounts: {
          wise_account.id.to_s => { account_type: "depository", balance: "200" }
        }
      }
    end

    assert_redirected_to accounts_path
  end

  test "complete_account_setup redirects with alert when no accounts provided" do
    post complete_account_setup_wise_item_url(@wise_item), params: { accounts: {} }

    assert_redirected_to setup_accounts_wise_item_url(@wise_item)
  end

  # ---------------------------------------------------------------------------
  # admin guard
  # ---------------------------------------------------------------------------

  test "non-admin cannot create a wise item" do
    sign_in users(:family_member)

    assert_no_difference "WiseItem.count" do
      post wise_items_url, params: {
        wise_item: { name: "Sneaky Wise", api_token: "sneak_token" }
      }
    end

    assert_redirected_to accounts_path
  end

  test "non-admin cannot destroy a wise item" do
    sign_in users(:family_member)

    delete wise_item_url(@wise_item)

    assert_redirected_to accounts_path
    assert_not @wise_item.reload.scheduled_for_deletion?
  end
end
