require "test_helper"

class PlaidItem::SyncerTest < ActiveSupport::TestCase
  setup do
    @plaid_item = plaid_items(:one)
  end

  # A Plaid rate change is dated to the sync. The syncer reads the clock once
  # and hands that date to the processing phase.
  test "the processing phase is given the sync's date" do
    dated = nil

    travel_to Time.zone.local(2026, 1, 15, 12, 0, 0) do
      @plaid_item.stubs(:import_latest_plaid_data)
      @plaid_item.stubs(:schedule_account_syncs)
      @plaid_item.expects(:process_accounts).with { |**kwargs| dated = kwargs[:as_of] }

      PlaidItem::Syncer.new(@plaid_item).perform_sync(stub_sync)
    end

    assert_equal Date.new(2026, 1, 15), dated
  end

  test "process_accounts hands its date to every account's processor" do
    date = Date.new(2026, 1, 15)
    processor = mock("processor")
    processor.stubs(:process)

    assert_not_empty @plaid_item.plaid_accounts
    @plaid_item.plaid_accounts.each do |plaid_account|
      PlaidAccount::Processor.expects(:new).with(plaid_account, as_of: date).returns(processor)
    end

    @plaid_item.process_accounts(as_of: date)
  end

  private
    def stub_sync
      sync = mock("sync")
      sync.stubs(:respond_to?).returns(true)
      sync.stubs(:sync_stats).returns({})
      sync.stubs(:created_at).returns(Time.current)
      sync.stubs(:window_start_date).returns(nil)
      sync.stubs(:window_end_date).returns(nil)
      sync.stubs(:update!)
      sync
    end
end
