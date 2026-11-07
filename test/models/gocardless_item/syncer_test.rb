# frozen_string_literal: true

require "test_helper"

class GocardlessItem::SyncerTest < ActiveSupport::TestCase
  setup do
    @item = families(:empty).gocardless_items.create!(name: "Test bank", secret_id: "test-id", secret_key: "test-key", requisition_id: "requisition-1")
  end

  test "an import failure does not skip processing and scheduling for linked accounts" do
    linked = mock("linked")
    linked.stubs(:includes).returns(linked)
    linked.stubs(:any?).returns(true)
    linked.stubs(:filter_map).returns([])
    @item.stubs(:linked_gocardless_accounts).returns(linked)
    @item.stubs(:unlinked_accounts_count).returns(0)
    @item.stubs(:import_latest_gocardless_data).raises(StandardError, "account 2 failed")
    @item.expects(:process_accounts).once
    @item.expects(:schedule_account_syncs).once

    sync = Sync.create!(syncable: @item)
    assert_raises(StandardError) { GocardlessItem::Syncer.new(@item).perform_sync(sync) }
  end
end
