require "test_helper"

class Transfer::PendingMatchTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @outflow = create_transaction(account: accounts(:depository), amount: 320, date: Date.current)
    @inflow = create_transaction(account: accounts(:credit_card), amount: -320, date: Date.current - 1)
    @transfer = Transfer.create!(outflow_transaction: @outflow.transaction, inflow_transaction: @inflow.transaction, status: "pending")
    @everything = [ accounts(:depository).id, accounts(:credit_card).id ]
  end

  test "each leg's counterpart is the other leg and its account" do
    from_outflow = Transfer::PendingMatch.new(@outflow.transaction.reload, visible_account_ids: @everything)
    from_inflow = Transfer::PendingMatch.new(@inflow.transaction.reload, visible_account_ids: @everything)

    assert_equal [ @inflow, accounts(:credit_card) ], [ from_outflow.counterpart_entry, from_outflow.counterpart_account ]
    assert_equal [ @outflow, accounts(:depository) ], [ from_inflow.counterpart_entry, from_inflow.counterpart_account ]
    assert_equal @transfer, from_outflow.transfer
  end

  test "the counterpart is shown and the transfer linked only to a viewer who can see the other account" do
    seen = Transfer::PendingMatch.new(@outflow.transaction.reload, visible_account_ids: @everything)
    hidden = Transfer::PendingMatch.new(@outflow.transaction.reload, visible_account_ids: [ accounts(:depository).id ])

    assert seen.counterpart_visible?
    assert seen.links_to_transfer?
    assert_not hidden.counterpart_visible?
    assert_not hidden.links_to_transfer?
  end

  test "a leg that is already a transfer row gets no second link to the transfer" do
    @outflow.transaction.update!(kind: "funds_movement")

    match = Transfer::PendingMatch.new(@outflow.transaction.reload, visible_account_ids: @everything)

    assert match.counterpart_visible?
    assert_not match.links_to_transfer?
  end
end
