class AddManualMergeExtIdIndex < ActiveRecord::Migration[7.2]
  disable_ddl_transaction!

  def change
    add_index :transactions,
      Arel.sql("(extra->'manual_merge'->>'merged_from_external_id')"),
      name: "idx_transactions_manual_merge_ext_id",
      where: "(extra ? 'manual_merge')",
      algorithm: :concurrently
  end
end
