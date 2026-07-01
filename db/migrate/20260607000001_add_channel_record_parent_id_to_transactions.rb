class AddChannelRecordParentIdToTransactions < ActiveRecord::Migration[7.2]
  def change
    add_column :transactions, :channel_record_parent_id, :uuid

    add_index :transactions, :channel_record_parent_id

    add_foreign_key :transactions, :transactions,
      column: :channel_record_parent_id,
      on_delete: :nullify
  end
end
