# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20261014081500_add_unique_transaction_indexes_to_transfers")

# The index swap builds concurrently, which cannot run inside a transaction, so
# these tests commit their DDL and put the schema's index back afterwards.
class AddUniqueTransactionIndexesToTransfersMigrationTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  INDEX = "index_transfers_on_inflow_transaction_id"
  TEMP_INDEX = "#{INDEX}_new"

  setup do
    @migration = AddUniqueTransactionIndexesToTransfers.new
    @migration.verbose = false
  end

  teardown do
    connection.execute("DROP INDEX IF EXISTS #{TEMP_INDEX}")
    unless connection.index_name_exists?(:transfers, INDEX)
      connection.add_index :transfers, :inflow_transaction_id, name: INDEX, unique: true
    end
  end

  # A run that stopped after dropping the old index but before the rename.
  test "a rerun keeps an already built replacement and finishes the swap" do
    connection.rename_index :transfers, INDEX, TEMP_INDEX
    built_oid = index_oid(TEMP_INDEX)

    @migration.send(:replace_index, :inflow_transaction_id, unique: true)

    assert_equal built_oid, index_oid(INDEX), "the finished replacement was dropped and rebuilt"
    assert_not connection.index_name_exists?(:transfers, TEMP_INDEX)
    assert connection.indexes(:transfers).find { |index| index.name == INDEX }.unique
  end

  test "a rerun rebuilds a leftover replacement that is not valid" do
    connection.rename_index :transfers, INDEX, TEMP_INDEX
    connection.execute(<<~SQL.squish)
      UPDATE pg_index SET indisvalid = FALSE WHERE indexrelid = to_regclass('#{TEMP_INDEX}')
    SQL
    invalid_oid = index_oid(TEMP_INDEX)

    @migration.send(:replace_index, :inflow_transaction_id, unique: true)

    assert_not_equal invalid_oid, index_oid(INDEX)
    assert_not connection.index_name_exists?(:transfers, TEMP_INDEX)
    assert connection.select_value("SELECT indisvalid FROM pg_index WHERE indexrelid = to_regclass('#{INDEX}')")
  end

  private
    def connection
      ActiveRecord::Base.connection
    end

    def index_oid(name)
      connection.select_value("SELECT to_regclass(#{connection.quote(name)})::oid")
    end
end

# The duplicate cleanup only runs while the per-column indexes are not unique,
# so each test swaps them for non-unique ones; DDL rolls back with the test.
class AddUniqueTransactionIndexesToTransfersCleanupTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    %i[inflow_transaction_id outflow_transaction_id].each do |column|
      connection.remove_index :transfers, name: "index_transfers_on_#{column}"
      connection.add_index :transfers, column, name: "index_transfers_on_#{column}"
    end

    @migration = AddUniqueTransactionIndexesToTransfers.new
    @migration.verbose = false
  end

  test "a pending duplicate loses to a confirmed transfer and leaves the freed kind alone" do
    outflow = create_transaction(account: accounts(:depository), amount: 100, kind: "funds_movement").entryable
    kept_inflow = create_transaction(account: accounts(:investment), amount: -100, kind: "funds_movement").entryable
    freed_entry = create_transaction(account: accounts(:credit_card), amount: -100, kind: "cc_payment", idempotency_key: SecureRandom.uuid)

    kept = insert_transfer(kept_inflow, outflow, "confirmed", 1.day.ago)
    loser = insert_transfer(freed_entry.entryable, outflow, "pending", 2.days.ago)
    fee = create_transaction(account: accounts(:depository), amount: 1).entryable
    fee.update_columns(transfer_id: loser)

    @migration.send(:resolve_duplicate_transfers)

    assert Transfer.exists?(kept)
    assert_not Transfer.exists?(loser)
    assert_equal "cc_payment", freed_entry.entryable.reload.kind
    assert_nil freed_entry.reload.idempotency_key
    assert_equal "funds_movement", outflow.reload.kind
    assert_nil fee.reload.transfer_id
  end

  test "a confirmed duplicate's legs are reset to standard unless a kept confirmed transfer owns them" do
    outflow = create_transaction(account: accounts(:depository), amount: 100, kind: "funds_movement").entryable
    kept_inflow = create_transaction(account: accounts(:investment), amount: -100).entryable
    freed_inflow = create_transaction(account: accounts(:credit_card), amount: -100, kind: "funds_movement").entryable
    pending_owned_entry = create_transaction(account: accounts(:loan), amount: -100, kind: "funds_movement", idempotency_key: SecureRandom.uuid)
    pending_owned = pending_owned_entry.entryable

    kept = insert_transfer(kept_inflow, outflow, "confirmed", 3.days.ago)
    loser = insert_transfer(freed_inflow, outflow, "confirmed", 2.days.ago)
    second_loser = insert_transfer(pending_owned, outflow, "confirmed", 1.day.ago)
    # The second loser's inflow is also in a pending transfer, which survives
    # but never set that transaction's kind.
    pending_survivor = insert_transfer(pending_owned, create_transaction(account: accounts(:depository), amount: 100).entryable, "pending", 4.days.ago)

    @migration.send(:resolve_duplicate_transfers)

    assert Transfer.exists?(kept)
    assert Transfer.exists?(pending_survivor)
    assert_not Transfer.exists?(loser)
    assert_not Transfer.exists?(second_loser)
    assert_equal "standard", freed_inflow.reload.kind
    assert_equal "standard", pending_owned.reload.kind
    assert_not_nil pending_owned_entry.reload.idempotency_key, "still in a transfer, so its key stays"
    # Shared with the confirmed losers, so re-derived for the kept transfer (into an investment account).
    assert_equal "investment_contribution", outflow.reload.kind
  end

  test "a transaction in two transfers in different roles keeps only one of them" do
    shared = create_transaction(account: accounts(:investment), amount: -100, kind: "funds_movement").entryable
    kept = insert_transfer(shared, create_transaction(account: accounts(:depository), amount: 100).entryable, "confirmed", 2.days.ago)
    loser_inflow = create_transaction(account: accounts(:credit_card), amount: -100).entryable
    loser = insert_transfer(loser_inflow, shared, "pending", 1.day.ago)

    @migration.send(:resolve_duplicate_transfers)

    assert Transfer.exists?(kept)
    assert_not Transfer.exists?(loser)
    assert_equal "funds_movement", shared.reload.kind
  end

  test "a kept confirmed transfer gets its kinds back from a deleted confirmed duplicate" do
    outflow = create_transaction(account: accounts(:depository), amount: 100, kind: "funds_movement").entryable
    loan_inflow = create_transaction(account: accounts(:loan), amount: -100, kind: "funds_movement").entryable
    other_inflow = create_transaction(account: accounts(:investment), amount: -100, kind: "funds_movement").entryable

    kept = insert_transfer(loan_inflow, outflow, "confirmed", 2.days.ago)
    insert_transfer(other_inflow, outflow, "confirmed", 1.day.ago)

    @migration.send(:resolve_duplicate_transfers)

    assert_equal [ kept ], Transfer.where(outflow_transaction_id: outflow.id).pluck(:id)
    assert_equal "loan_payment", outflow.reload.kind
    assert_equal "funds_movement", loan_inflow.reload.kind
    assert_equal "standard", other_inflow.reload.kind
  end

  private
    def connection
      ActiveRecord::Base.connection
    end

    def insert_transfer(inflow, outflow, status, created_at)
      Transfer.insert!(
        { inflow_transaction_id: inflow.id, outflow_transaction_id: outflow.id, status: status, created_at: created_at, updated_at: created_at },
        returning: :id
      ).first["id"]
    end
end
