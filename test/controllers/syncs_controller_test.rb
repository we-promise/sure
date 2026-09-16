require "test_helper"

class SyncsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
  end

  test "member can cancel their family's sync" do
    sync = Sync.create!(syncable: @user.family, status: :syncing)

    post cancel_sync_path(sync)

    assert_redirected_to accounts_path
    assert_not_nil sync.reload.cancel_requested_at
  end

  test "cancelling a finished sync is a no-op with an alert" do
    sync = Sync.create!(syncable: @user.family, status: :completed)

    post cancel_sync_path(sync)

    assert_redirected_to accounts_path
    assert_equal I18n.t("syncs.cancel.not_cancellable"), flash[:alert]
    assert_equal "completed", sync.reload.status
  end

  test "cannot cancel another family's sync" do
    other_family_sync = Sync.create!(syncable: users(:empty).family, status: :syncing)

    post cancel_sync_path(other_family_sync)

    assert_response :not_found
    assert_equal "syncing", other_family_sync.reload.status
  end

  test "non-admin member cannot cancel a provider item sync" do
    sign_in users(:family_member)
    provider_sync = Sync.create!(syncable: plaid_items(:one), status: :syncing)

    post cancel_sync_path(provider_sync)

    assert_response :not_found
    assert_equal "syncing", provider_sync.reload.status
  end

  test "admin can cancel a provider item sync" do
    provider_sync = Sync.create!(syncable: plaid_items(:one), status: :syncing)

    post cancel_sync_path(provider_sync)

    assert_redirected_to accounts_path
    assert_not_nil provider_sync.reload.cancel_requested_at
  end
end
