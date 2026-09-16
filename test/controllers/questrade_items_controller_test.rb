# frozen_string_literal: true

require "test_helper"

class QuestradeItemsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
    SyncJob.stubs(:perform_later)

    @family = families(:dylan_family)
    @questrade_item = questrade_items(:one)
  end

  # ---------------------------------------------------------------------------
  # create
  # ---------------------------------------------------------------------------

  test "create adds a new questrade connection" do
    assert_difference "QuestradeItem.count", 1 do
      post questrade_items_url, params: {
        questrade_item: { name: "Business Questrade", refresh_token: "new_token_abc" }
      }
    end

    assert_redirected_to settings_providers_path
    assert_equal "new_token_abc", @family.questrade_items.find_by!(name: "Business Questrade").refresh_token
  end

  test "create uses localized default name when submitted name is blank" do
    assert_difference "QuestradeItem.count", 1 do
      post questrade_items_url, params: {
        questrade_item: { name: "  ", refresh_token: "default_name_token" }
      }
    end

    assert_redirected_to settings_providers_path
    assert_equal I18n.t("questrade_items.default_name"), @family.questrade_items.order(:created_at).last.name
  end

  # ---------------------------------------------------------------------------
  # update
  # ---------------------------------------------------------------------------

  test "update renames item and resets status to good when new token provided" do
    @questrade_item.update!(status: :requires_update)

    patch questrade_item_url(@questrade_item), params: {
      questrade_item: { name: "Renamed Questrade", refresh_token: "refreshed_token" }
    }

    @questrade_item.reload
    assert_redirected_to settings_providers_path
    assert_equal "Renamed Questrade", @questrade_item.name
    assert_equal "refreshed_token", @questrade_item.refresh_token
    assert_equal "good", @questrade_item.status
  end

  test "update with blank token preserves existing token" do
    original_token = @questrade_item.refresh_token

    patch questrade_item_url(@questrade_item), params: {
      questrade_item: { name: "Renamed Questrade", refresh_token: "" }
    }

    @questrade_item.reload
    assert_redirected_to settings_providers_path
    assert_equal "Renamed Questrade", @questrade_item.name
    assert_equal original_token, @questrade_item.refresh_token
  end

  # ---------------------------------------------------------------------------
  # destroy
  # ---------------------------------------------------------------------------

  test "destroy schedules the item for deletion" do
    delete questrade_item_url(@questrade_item)

    assert_redirected_to settings_providers_path
    assert @questrade_item.reload.scheduled_for_deletion?
  end

  # ---------------------------------------------------------------------------
  # sync
  # ---------------------------------------------------------------------------

  test "sync enqueues a sync job" do
    assert_difference -> { Sync.where(syncable: @questrade_item).count }, 1 do
      post sync_questrade_item_url(@questrade_item)
    end

    assert_response :redirect
  end

  test "sync is a no-op when item is already syncing" do
    @questrade_item.syncs.create!(status: :syncing)

    assert_no_difference -> { Sync.where(syncable: @questrade_item).count } do
      post sync_questrade_item_url(@questrade_item)
    end

    assert_response :redirect
  end

  # ---------------------------------------------------------------------------
  # select_accounts / link_accounts
  # ---------------------------------------------------------------------------

  test "select_accounts redirects to setup_accounts when credentials configured" do
    get select_accounts_questrade_items_url

    assert_redirected_to setup_accounts_questrade_item_url(@questrade_item)
  end

  test "select_accounts redirects to settings when credentials not configured" do
    @questrade_item.update_column(:refresh_token, nil)

    get select_accounts_questrade_items_url

    assert_redirected_to settings_providers_path
  end

  test "link_accounts creates new accounts for selected questrade_accounts" do
    questrade_account = @questrade_item.questrade_accounts.create!(
      name: "RRSP (87654321)",
      questrade_account_id: "87654321",
      account_type: "RRSP",
      currency: "CAD",
      current_balance: 5000
    )

    assert_difference "Account.count", 1 do
      assert_difference "AccountProvider.count", 1 do
        post link_accounts_questrade_items_url, params: {
          selected_account_ids: [ questrade_account.id ],
          accountable_type: "Investment"
        }
      end
    end

    assert_redirected_to accounts_path
  end

  test "link_accounts redirects to settings when no credentials configured" do
    @questrade_item.update_column(:refresh_token, nil)

    post link_accounts_questrade_items_url, params: {
      selected_account_ids: [ 999 ]
    }

    assert_redirected_to settings_providers_path
  end

  test "link_accounts redirects when no account ids selected" do
    post link_accounts_questrade_items_url, params: { selected_account_ids: [] }

    assert_redirected_to select_accounts_questrade_items_url
  end

  # ---------------------------------------------------------------------------
  # setup_accounts / complete_account_setup
  # ---------------------------------------------------------------------------

  test "setup_accounts renders unlinked accounts" do
    get setup_accounts_questrade_item_url(@questrade_item)

    assert_response :success
  end

  test "complete_account_setup creates accounts from config and redirects" do
    questrade_account = @questrade_item.questrade_accounts.create!(
      name: "Margin (11111111)",
      questrade_account_id: "11111111",
      account_type: "Margin",
      currency: "CAD",
      current_balance: 3000
    )

    assert_difference "Account.count", 1 do
      post complete_account_setup_questrade_item_url(@questrade_item), params: {
        accounts: {
          questrade_account.id.to_s => { account_type: "investment", balance: "3000" }
        }
      }
    end

    assert_redirected_to accounts_path
  end

  test "complete_account_setup redirects with alert when no accounts provided" do
    post complete_account_setup_questrade_item_url(@questrade_item), params: { accounts: {} }

    assert_redirected_to setup_accounts_questrade_item_url(@questrade_item)
  end

  # ---------------------------------------------------------------------------
  # admin guard
  # ---------------------------------------------------------------------------

  test "non-admin cannot create a questrade item" do
    sign_in users(:family_member)

    assert_no_difference "QuestradeItem.count" do
      post questrade_items_url, params: {
        questrade_item: { name: "Sneaky Questrade", refresh_token: "sneak_token" }
      }
    end

    assert_redirected_to accounts_path
  end

  test "non-admin cannot destroy a questrade item" do
    sign_in users(:family_member)

    delete questrade_item_url(@questrade_item)

    assert_redirected_to accounts_path
    assert_not @questrade_item.reload.scheduled_for_deletion?
  end
end
