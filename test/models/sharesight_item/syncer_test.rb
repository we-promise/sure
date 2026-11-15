require "test_helper"

class SharesightItem::SyncerTest < ActiveSupport::TestCase
  setup do
    @item = families(:dylan_family).sharesight_items.create!(name: "Sharesight", client_id: "client-id", client_secret: "client-secret")
    @sync = @item.syncs.create!
  end

  test "a connection without its API client needs an update" do
    @item.update_columns(client_secret: nil)

    assert_raises(Provider::Sharesight::ConfigurationError) { SharesightItem::Syncer.new(@item).perform_sync(@sync) }
    assert @item.reload.requires_update?
  end

  test "flags portfolios that still need linking" do
    @item.sharesight_accounts.create!(name: "Shares", currency: "AUD", sharesight_account_id: "42")
    @item.expects(:import_latest_data)
    @item.expects(:process_accounts).never

    SharesightItem::Syncer.new(@item).perform_sync(@sync)

    assert @item.reload.pending_account_setup?
  end
end
