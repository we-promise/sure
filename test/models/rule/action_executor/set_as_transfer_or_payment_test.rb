require "test_helper"

class Rule::ActionExecutor::SetAsTransferOrPaymentTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @rule = rules(:one)
    @executor = Rule::ActionExecutor::SetAsTransferOrPayment.new(@rule)
    @family = families(:dylan_family)
  end

  # Regression: the executor's guard is `unless txn.transfer?`, which is
  # kind-based (Transaction::TRANSFER_KINDS), not association-based. A
  # transaction that auto-match has already paired but that no one has
  # confirmed yet still reads kind "standard", so the guard lets it through
  # and the executor builds a SECOND Transfer for it -- tripping Transfer's
  # per-column uniqueness validation on outflow_transaction_id.
  #
  # Nothing rescues that: Rule#apply has no per-resource rescue, so RuleJob
  # marks the whole run failed, re-raises into a Sidekiq retry, and every
  # remaining transaction in the rule is skipped. Family::Syncer#perform_post_sync
  # runs auto_match_transfers! and then enqueues every active rule, so this is
  # reachable on an ordinary sync, not just under a race.
  test "skips a transaction that is already one leg of a pending auto-matched transfer" do
    outflow_entry = create_transaction(date: Date.current, account: accounts(:depository), amount: 500)
    create_transaction(date: Date.current, account: accounts(:credit_card), amount: -500)

    @family.auto_match_transfers!

    outflow_transaction = outflow_entry.transaction.reload
    assert outflow_transaction.transfer.present?, "auto-match did not pair the two 500 transactions"
    assert outflow_transaction.transfer.pending?

    scope = Transaction.where(id: outflow_transaction.id)

    assert_nothing_raised do
      @executor.execute(scope, value: accounts(:other_asset).id)
    end

    assert_equal 1, Transfer.where(outflow_transaction_id: outflow_transaction.id).count,
      "the executor must not create a competing transfer for an already-matched transaction"
  end

  # The same guard, exercised through the public entry point, to show the
  # blast radius: one already-matched transaction must not stop the rule from
  # processing the others.
  test "an already-matched transaction does not abort the rest of the rule run" do
    outflow_entry = create_transaction(date: Date.current, account: accounts(:depository), amount: 500)
    create_transaction(date: Date.current, account: accounts(:credit_card), amount: -500)
    unmatched_entry = create_transaction(date: Date.current, account: accounts(:depository), amount: 123)

    @family.auto_match_transfers!

    scope = Transaction.where(id: [ outflow_entry.transaction.id, unmatched_entry.transaction.id ])

    assert_nothing_raised do
      @executor.execute(scope, value: accounts(:other_asset).id)
    end

    assert unmatched_entry.transaction.reload.transfer.present?,
      "the unmatched transaction should still have been converted into a transfer"
  end

  # An already-confirmed transfer was always skipped, because confirming sets
  # kind. Pinning it here so a fix to the guard above can't regress it.
  test "skips a transaction that is one leg of a confirmed transfer" do
    outflow_entry = create_transaction(date: Date.current, account: accounts(:depository), amount: 500)
    create_transaction(date: Date.current, account: accounts(:credit_card), amount: -500)

    @family.auto_match_transfers!
    outflow_entry.transaction.reload.transfer.confirm!

    scope = Transaction.where(id: outflow_entry.transaction.id)

    assert_nothing_raised do
      @executor.execute(scope, value: accounts(:other_asset).id)
    end

    assert_equal 1, Transfer.where(outflow_transaction_id: outflow_entry.transaction.id).count
  end
end
