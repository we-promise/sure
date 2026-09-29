require "test_helper"

class EntryReconciliationTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @account = accounts(:depository)
    @statement = create_statement
  end

  test "an entry with no provenance is uncleared" do
    entry = create_transaction(account: @account)

    assert_equal :uncleared, entry.reconciliation_state
    assert_not entry.cleared?
    assert_not entry.reconciled?
  end

  test "an entry carrying provider provenance is cleared without storing a flag" do
    from_external_id = create_transaction(account: @account, external_id: "plaid-1")
    from_source = create_transaction(account: @account, source: "simplefin")

    assert_equal :cleared, from_external_id.reconciliation_state
    assert_equal :cleared, from_source.reconciliation_state
  end

  test "reconciled outranks cleared" do
    entry = create_transaction(account: @account, source: "plaid")
    entry.mark_reconciled!(statement: @statement)

    assert_equal :reconciled, entry.reload.reconciliation_state
    assert_equal @statement, entry.reconciled_by_statement
  end

  test "reconciling is reversible but clearing is not affected by it" do
    entry = create_transaction(account: @account, source: "plaid")
    entry.mark_reconciled!(statement: @statement)
    entry.unmark_reconciled!

    assert_equal :cleared, entry.reload.reconciliation_state
    assert_nil entry.reconciled_at
    assert_nil entry.reconciled_by_statement_id
  end

  test "an entry can be reconciled by hand with no statement on file" do
    entry = create_transaction(account: @account)
    entry.mark_reconciled!

    assert entry.reload.reconciled?
    assert_nil entry.reconciled_by_statement_id
  end

  test "an entry cannot cite a statement without being reconciled" do
    entry = create_transaction(account: @account)
    entry.reconciled_by_statement = @statement

    # Mirrors chk_entries_reconciled_at_present_when_statement_set: the model
    # rejects it before the database constraint is reached.
    assert_not entry.valid?
    assert_predicate entry.errors[:reconciled_at], :any?
  end

  test "scopes partition reconciled from unreconciled" do
    reconciled = create_transaction(account: @account)
    unreconciled = create_transaction(account: @account)
    reconciled.mark_reconciled!(statement: @statement)

    assert_includes Entry.reconciled, reconciled
    assert_not_includes Entry.reconciled, unreconciled
    assert_includes Entry.unreconciled, unreconciled
    assert_includes Entry.reconciled_by(@statement), reconciled
  end

  test "deleting the statement leaves the entry reconciled but unevidenced" do
    entry = create_transaction(account: @account)
    entry.mark_reconciled!(statement: @statement)

    @statement.destroy!

    entry.reload
    assert entry.reconciled?, "reconciliation should survive losing the evidence"
    assert_nil entry.reconciled_by_statement_id
  end

  private

    def create_statement(account: @account, filename: "statement.pdf")
      AccountStatement.create_from_upload!(
        family: account.family,
        account: account,
        file: uploaded_file(
          filename: filename,
          content_type: "application/pdf",
          content: file_fixture("imports/sample_bank_statement.pdf").binread
        )
      )
    end
end
