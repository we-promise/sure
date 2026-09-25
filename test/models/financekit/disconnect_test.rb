require "test_helper"
require_relative "../../support/financekit_test_helper"

class Financekit::DisconnectTest < ActiveSupport::TestCase
  include FinancekitTestHelper
  include ActiveJob::TestHelper

  setup { financekit_setup }

  test "a retain disconnect revokes the connection and keeps everything it imported" do
    accept_and_apply
    account = @source.account

    @item.disconnect!

    assert_equal "revoked", @item.reload.status
    assert_nil @item.purge_requested_at
    assert Account.exists?(account.id)
    assert_equal 1, account.entries.where(source: "financekit").count
    assert_equal 1, @source.financekit_transactions.count
    assert_equal 1, @source.financekit_balance_observations.count
    assert_not @source.financekit_account_lineage.reload.discarded?
  end

  test "a discard records the request and hands the deletion to a job" do
    accept_and_apply

    assert_enqueued_with(job: FinancekitPurgeJob) { @item.disconnect!(disposition: "discard") }

    # Accepted, not done: the marker is what makes the request survive a lost job.
    assert_not_nil @item.reload.purge_requested_at
    assert_nil @item.purge_completed_at
    assert @item.purge_pending?
  end

  test "a discard destroys an account FinanceKit created" do
    accept_and_apply
    account = @source.account
    lineage = @source.financekit_account_lineage
    assert_equal "created", lineage.account_origin

    discard!

    assert_not Account.exists?(account.id)
    # A destroyed account has no balance to recompute.
    assert_empty FinancekitTransaction.where(financekit_account_lineage: lineage)
    assert_empty FinancekitBalanceObservation.where(financekit_account_lineage: lineage)
    assert lineage.reload.discarded?
    # Nulled so a later enrollment cannot resurrect a link to an account this
    # lineage no longer describes.
    assert_nil lineage.account_id
    assert_not_nil @item.reload.purge_completed_at
  end

  test "a discard empties an account the family already had and leaves it standing" do
    accept_and_apply
    account = @source.account
    manual = account.entries.create!(name: "Rent", amount: "1200.00", currency: "USD",
      date: Date.new(2026, 9, 1), entryable: Transaction.new)
    link_lineage!

    discard!

    assert Account.exists?(account.id)
    assert_equal [ manual.id ], account.entries.reload.pluck(:id)
    assert @source.financekit_account_lineage.reload.discarded?
  end

  test "a discard hands an emptied account back to sync so its balance matches what remains" do
    accept_and_apply
    link_lineage!
    # Asserted on the call rather than on an enqueue: sync_later reuses a visible
    # sync, and the import that just ran already created one.
    Account.any_instance.expects(:sync_later).at_least_once

    discard!
  end

  test "a discard removes imported entries the family reconciled or edited" do
    accept_and_apply
    entry = @source.account.entries.sole
    entry.mark_reconciled!
    entry.mark_user_modified!
    link_lineage!

    discard!

    # The import is being undone at the family's request, so the rules that stop
    # a *sync* from overwriting their work do not apply here.
    assert_not Entry.exists?(entry.id)
  end

  test "a discard takes a split parent's children with it" do
    accept_and_apply
    entry = @source.account.entries.sole
    children = entry.split!([ { name: "Half", amount: entry.amount / 2 },
      { name: "Other half", amount: entry.amount / 2 } ])
    link_lineage!

    discard!

    assert_not Entry.exists?(entry.id)
    # Entry refuses to destroy a child on its own, so the children can only go
    # with the parent -- through the association or the parent_entry_id cascade.
    # Pinned because a purge that spared the parent would strand them.
    assert_empty Entry.where(id: children.map(&:id))
  end

  test "a discard unlinks a transfer but keeps the account on the other side" do
    accept_and_apply
    entry = @source.account.entries.sole
    other_account = @family.accounts.create!(name: "Transfer destination", balance: 0, currency: "USD",
      accountable: Depository.new(subtype: "checking"))
    other = other_account.entries.create!(name: "Transfer in", amount: -entry.amount, currency: entry.currency,
      date: entry.date, entryable: Transaction.new)
    transfer = Transfer.create!(inflow_transaction: other.transaction, outflow_transaction: entry.transaction)
    link_lineage!

    discard!

    assert_not Transfer.exists?(transfer.id)
    # The counterpart is the other account's own entry. It loses the pairing, not
    # its existence.
    assert Entry.exists?(other.id)
    assert_nil other.transaction.reload.transfer
  end

  test "a discard leaves a lineage another live connection still publishes into" do
    accept_and_apply
    account = @source.account
    lineage = @source.financekit_account_lineage
    replacement = replacement_connection!

    @item.disconnect!(disposition: "discard")
    counts = Financekit::Purge.new(@item).perform!

    # A replacement device shares the lineage for as long as both connections
    # exist. Discarding the old one must not delete the new one's live account.
    assert_equal "active", replacement.reload.status
    assert Account.exists?(account.id)
    assert_equal 1, account.entries.where(source: "financekit").count
    assert_not lineage.reload.discarded?
    assert_equal 1, counts["lineages_skipped"]
  end

  test "the sweep finishes a discard whose job never ran" do
    accept_and_apply
    account = @source.account
    @item.disconnect!(disposition: "discard")
    assert @item.reload.purge_pending?

    # Stands in for an enqueue that failed or a worker that died holding the job.
    FinancekitInboxJob.perform_now

    assert_not Account.exists?(account.id)
    assert_not_nil @item.reload.purge_completed_at
  end

  test "a provider that has not declared discard offers only retain" do
    unconverted = Class.new { include ProviderDisconnectable }

    assert_equal %w[retain discard], FinancekitItem.supported_dispositions
    assert_equal %w[retain], unconverted.supported_dispositions
    # Rejected rather than quietly downgraded to retain: telling a family their
    # data was deleted when it was not is the failure that matters here.
    assert_raises(ArgumentError) { unconverted.new.disposition!("discard") }
    assert_equal "retain", unconverted.new.disposition!(nil)
  end

  test "an unknown disposition is refused" do
    assert_raises(ArgumentError) { @item.disconnect!(disposition: "shred") }
    # Refused before anything is revoked, so a typo cannot cost a connection.
    assert_equal "active", @item.reload.status
  end

  private

    def discard!(item = @item)
      item.disconnect!(disposition: "discard")
      Financekit::Purge.new(item).perform!
    end

    # The helper's mapping uses action "create". Flipping the origin is how these
    # tests cover the linked case without rebuilding the whole enrollment: what
    # the mapping writes is covered in mapping_test.
    def link_lineage!
      @source.financekit_account_lineage.update!(account_origin: "linked")
    end

    def replacement_connection!
      enrollment = @enrollment.deep_dup
      enrollment["enrollment_id"] = SecureRandom.uuid
      enrollment["replaces_connection_id"] = @item.id
      replacement = Financekit::Enrollment.create!(@user, enrollment).item
      FinancekitAccount.map!(replacement, @source_id,
        @mapping_input.except("booked_balance", "observed_at").merge("action" => "link",
          "account_id" => @source.account.id, "lineage_id" => @source.financekit_account_lineage_id))
      replacement.activate!
      replacement
    end
end
