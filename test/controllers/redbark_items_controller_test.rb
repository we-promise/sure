# frozen_string_literal: true

require "test_helper"

class RedbarkItemsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
    SyncJob.stubs(:perform_later)

    @family = families(:dylan_family)
    @redbark_item = redbark_items(:one)
    @redbark_account = redbark_accounts(:savings_account)
  end

  test "create adds a new redbark connection" do
    family = users(:empty).family
    sign_in users(:empty)

    assert_difference "RedbarkItem.count", 1 do
      post redbark_items_url, params: {
        redbark_item: { api_key: "rbk_live_new_key" }
      }
    end

    item = family.redbark_items.order(:created_at).last
    assert_equal "rbk_live_new_key", item.api_key
  end

  test "create with blank api key is rejected" do
    assert_no_difference "RedbarkItem.count" do
      post redbark_items_url, params: {
        redbark_item: { api_key: "" }
      }
    end
  end

  test "update rotates the api key and clears requires_update" do
    @redbark_item.update!(status: :requires_update)

    patch redbark_item_url(@redbark_item), params: {
      redbark_item: { api_key: "rbk_live_rotated" }
    }

    @redbark_item.reload
    assert_equal "rbk_live_rotated", @redbark_item.api_key
    assert @redbark_item.good?
  end

  test "blank api key update is rejected and preserves the stored key" do
    original_key = @redbark_item.api_key

    patch redbark_item_url(@redbark_item), params: {
      redbark_item: { api_key: "" }
    }

    assert_equal original_key, @redbark_item.reload.api_key
  end

  test "sync enqueues a sync" do
    RedbarkItem.any_instance.stubs(:syncing?).returns(false)
    RedbarkItem.any_instance.expects(:sync_later).once

    post sync_redbark_item_url(@redbark_item)
    assert_response :redirect
  end

  test "destroy schedules the connection for deletion" do
    delete redbark_item_url(@redbark_item)

    assert_redirected_to settings_providers_path
    assert @redbark_item.reload.scheduled_for_deletion?
  end

  test "complete_account_setup creates and links an account" do
    assert_difference "Account.count", 1 do
      post complete_account_setup_redbark_item_url(@redbark_item), params: {
        accounts: { @redbark_account.id => { account_type: "depository" } }
      }
    end

    @redbark_account.reload
    assert @redbark_account.account_provider.present?
    assert_equal "Depository", @redbark_account.account.accountable_type
    assert_not @redbark_account.ignored?
  end

  test "complete_account_setup skip marks the account ignored" do
    assert_no_difference "Account.count" do
      post complete_account_setup_redbark_item_url(@redbark_item), params: {
        accounts: { @redbark_account.id => { account_type: "skip" } }
      }
    end

    assert @redbark_account.reload.ignored?
    assert_not @redbark_item.reload.unlinked_redbark_accounts.exists?(id: @redbark_account.id)
  end
end
