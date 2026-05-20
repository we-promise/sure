# frozen_string_literal: true

require "test_helper"

class Account::SchedulesBalanceSyncsTest < ActiveSupport::TestCase
  setup do
    @item = plaid_items(:one)
    @account = accounts(:depository)
    @parent_sync = @item.syncs.create!
  end

  test "schedule_account_syncs_for passes derived incremental window to account sync" do
    expected_window = 5.days.ago.to_date

    Account::BalanceSyncWindow.stubs(:for_account).returns(expected_window)

    @account.expects(:sync_later).with(
      parent_sync: @parent_sync,
      window_start_date: expected_window,
      window_end_date: nil
    ).once

    @item.schedule_account_syncs_for(
      [ @account ],
      parent_sync: @parent_sync
    )
  end
end
