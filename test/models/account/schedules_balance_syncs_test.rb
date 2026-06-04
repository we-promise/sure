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

  test "schedule_account_syncs_for continues scheduling remaining accounts when one fails" do
    other_account = accounts(:credit_card)
    expected_window = 5.days.ago.to_date

    Account::BalanceSyncWindow.stubs(:for_account).returns(expected_window)

    @account.expects(:sync_later).raises(StandardError, "sync failed")
    other_account.expects(:sync_later).with(
      parent_sync: @parent_sync,
      window_start_date: expected_window,
      window_end_date: nil
    ).once

    results = @item.schedule_account_syncs_for(
      [ @account, other_account ],
      parent_sync: @parent_sync,
      report_results: true
    )

    assert_equal 2, results.size
    assert_equal @account.id, results[0][:account_id]
    assert_equal false, results[0][:success]
    assert_equal "sync failed", results[0][:error]
    assert_equal other_account.id, results[1][:account_id]
    assert_equal true, results[1][:success]
  end
end
