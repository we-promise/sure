# These columns are reserved for Phase 2 bond holdings snapshot caching.
# No application code uses them yet — they are scaffolded here so the schema
# is ready when the snapshot feature is implemented.
class AddHoldingsSnapshotColumnsToAccounts < ActiveRecord::Migration[7.2]
  def up
    add_column :accounts, :holdings_snapshot_data, :jsonb unless column_exists?(:accounts, :holdings_snapshot_data)
    add_column :accounts, :holdings_snapshot_at, :datetime unless column_exists?(:accounts, :holdings_snapshot_at)
  end

  def down
    remove_column :accounts, :holdings_snapshot_data if column_exists?(:accounts, :holdings_snapshot_data)
    remove_column :accounts, :holdings_snapshot_at if column_exists?(:accounts, :holdings_snapshot_at)
  end
end
