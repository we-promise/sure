# frozen_string_literal: true

require "test_helper"

class IndexaCapitalItem::SyncerTest < ActiveSupport::TestCase
  setup do
    @item = indexa_capital_items(:configured_with_token)
    @item.stubs(:import_latest_indexa_capital_data)
  end

  test "ignored accounts do not leave the connection waiting for setup" do
    @item.indexa_capital_accounts.each(&:ignore!)
    sync = Sync.create!(syncable: @item)

    IndexaCapitalItem::Syncer.new(@item).perform_sync(sync)

    assert_not @item.reload.pending_account_setup?
    assert_equal 0, sync.reload.sync_stats["unlinked_accounts"]
  end
end
