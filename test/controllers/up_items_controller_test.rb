require "test_helper"

class UpItemsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
    @item = UpItem.create!(family: families(:dylan_family), name: "Up", access_token: "existing-token")
  end

  test "settings updates use the lifecycle boundary and omit a blank token" do
    lifecycle = mock("Up lifecycle")
    UpItem::Lifecycle.expects(:new).with(@item).returns(lifecycle)
    lifecycle.expects(:update_settings).with do |attributes|
      attributes.to_h == { "name" => "Renamed" }
    end.returns(@item)

    patch up_item_url(@item), params: { up_item: { name: "Renamed", access_token: "" } }

    assert_redirected_to settings_providers_path
    assert_equal "existing-token", @item.reload.access_token
  end

  test "a denied settings operation leaves the source unchanged and logs no exception text" do
    lifecycle = mock("denied Up lifecycle")
    UpItem::Lifecycle.expects(:new).with(@item).returns(lifecycle)
    lifecycle.expects(:update_settings).raises(Provider::AccountData::LegacyWriterFence::OwnershipChanged, "private-context")
    DebugLogEntry.expects(:capture).with do |attributes|
      attributes[:family] == @item.family && attributes[:provider_key] == "up" &&
        attributes.dig(:metadata, :up_item_id) == @item.id &&
        attributes.dig(:metadata, :error_class) == Provider::AccountData::LegacyWriterFence::OwnershipChanged.name &&
        !attributes.to_json.include?("private-context")
    end

    patch up_item_url(@item), params: { up_item: { name: "Rejected" } }

    assert_redirected_to settings_providers_path
    assert_equal "Up", @item.reload.name
  end

  test "deletion uses the combined unlink and schedule operation" do
    lifecycle = mock("Up disconnect")
    UpItem::Lifecycle.expects(:new).with(@item).returns(lifecycle)
    lifecycle.expects(:disconnect).returns([])
    UpItem.any_instance.expects(:unlink_all!).never
    UpItem.any_instance.expects(:destroy_later).never

    delete up_item_url(@item)

    assert_redirected_to settings_providers_path
  end

  test "account setup forwards choices through the lifecycle boundary" do
    source = @item.up_accounts.create!(account_id: "skip", name: "Skipped", currency: "AUD")
    lifecycle = mock("Up account setup")
    UpItem::Lifecycle.expects(:new).with(@item).returns(lifecycle)
    lifecycle.expects(:complete_account_setup).with do |account_types:|
      account_types[source.id] == "skip"
    end.returns(created_accounts: [], skipped_count: 1)

    post complete_account_setup_up_item_url(@item), params: { account_types: { source.id => "skip" } }

    assert_redirected_to accounts_path
    assert_equal I18n.t("up_items.complete_account_setup.all_skipped"), flash[:notice]
  end

  test "non-admins cannot enter the lifecycle boundary" do
    sign_in users(:family_member)
    UpItem::Lifecycle.expects(:new).never

    patch up_item_url(@item), params: { up_item: { name: "Rejected" } }

    assert_equal "Up", @item.reload.name
    assert_response :redirect
  end

  test "manual sync delegates the selected item and signed in actor to ownership admission" do
    command = mock("Up manual sync")
    UpItem::SyncRequest.expects(:new).with(item: @item, actor: users(:family_admin)).returns(command)
    command.expects(:call)
    UpItem.any_instance.expects(:sync_later).never

    post sync_up_item_url(@item)

    assert_redirected_to accounts_path
  end

  test "manual sync preserves its JSON response through the same command" do
    command = mock("Up JSON sync")
    UpItem::SyncRequest.expects(:new).with(item: @item, actor: users(:family_admin)).returns(command)
    command.expects(:call)

    post sync_up_item_url(@item), as: :json

    assert_response :ok
  end

  test "changed ownership from manual sync is sanitized and refused" do
    command = mock("stale Up sync")
    UpItem::SyncRequest.expects(:new).returns(command)
    command.expects(:call).raises(Provider::AccountData::LegacyWriterFence::OwnershipChanged, "private-context")
    DebugLogEntry.expects(:capture).with do |attributes|
      attributes[:provider_key] == "up" && !attributes.to_json.include?("private-context")
    end

    post sync_up_item_url(@item)

    assert_redirected_to settings_providers_path
    assert_equal I18n.t("up_items.setup_accounts.api_error"), flash[:alert]
  end

  test "a non-admin cannot dispatch a manual sync" do
    sign_in users(:family_member)
    UpItem::SyncRequest.expects(:new).never

    post sync_up_item_url(@item)

    assert_redirected_to accounts_path
  end

  test "another family's item cannot reach manual sync admission" do
    foreign = UpItem.create!(family: families(:empty), name: "Foreign Up", access_token: "private-foreign-token")
    UpItem::SyncRequest.expects(:new).never

    post sync_up_item_url(foreign)

    assert_response :not_found
  end
end
