# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20261122100200_restore_kinds_of_pending_transfer_matches")

class RestoreKindsOfPendingTransferMatchesMigrationTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:dylan_family)
  end

  test "gives pending matches left at the standard kind their transfer kinds" do
    transfer = pending_transfer(to: accounts(:credit_card))

    run_migration

    assert_equal "cc_payment", transfer.outflow_transaction.reload.kind
    assert_equal "funds_movement", transfer.inflow_transaction.reload.kind
    assert transfer.reload.pending?
  end

  test "leaves families that confirm matches first alone" do
    @family.update!(require_transfer_match_confirmation: true)
    transfer = pending_transfer(to: accounts(:credit_card))

    run_migration

    assert_equal "standard", transfer.outflow_transaction.reload.kind
    assert_equal "standard", transfer.inflow_transaction.reload.kind
  end

  test "leaves a leg with a kind of the user's own alone" do
    transfer = pending_transfer(to: accounts(:credit_card), outflow_kind: "one_time")

    run_migration

    assert_equal "one_time", transfer.outflow_transaction.reload.kind
    assert_equal "standard", transfer.inflow_transaction.reload.kind
  end

  test "can be run again" do
    transfer = pending_transfer(to: accounts(:credit_card))

    2.times { run_migration }

    assert_equal "cc_payment", transfer.outflow_transaction.reload.kind
  end

  private
    def pending_transfer(to:, outflow_kind: "standard")
      outflow = create_transaction(date: Date.current, account: accounts(:depository), amount: 500, kind: outflow_kind)
      inflow = create_transaction(date: Date.current, account: to, amount: -500)

      Transfer.create!(inflow_transaction: inflow.transaction, outflow_transaction: outflow.transaction)
    end

    def run_migration
      ActiveRecord::Migration.suppress_messages do
        RestoreKindsOfPendingTransferMatches.new.up
      end
    end
end
