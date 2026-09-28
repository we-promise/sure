require "test_helper"

class EntriesHelperTest < ActionView::TestCase
  include EntriesTestHelper

  test "deduplicating transfers preserves sort order and an isolated inflow" do
    transfer = create_transfer(from_account: accounts(:depository), to_account: accounts(:credit_card), amount: 50)
    outflow = transfer.outflow_transaction.reload.entry
    inflow = transfer.inflow_transaction.reload.entry
    large = create_transaction(amount: 100)
    small = create_transaction(amount: 10)

    assert_equal [ large, outflow, small ], entries_without_duplicate_transfers([ large, inflow, outflow, small ])
    assert_equal [ large, inflow, small ], entries_without_duplicate_transfers([ large, inflow, small ])
  end
end
