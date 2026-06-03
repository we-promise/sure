class CreateRetirementBucketEntries < ActiveRecord::Migration[7.2]
  def change
    create_table :retirement_bucket_entries, id: :uuid do |t|
      t.references :goal_retirement, type: :uuid, null: false,
        foreign_key: { to_table: :goals, on_delete: :cascade }
      t.references :account, type: :uuid, null: false,
        foreign_key: { on_delete: :cascade }

      t.timestamps
    end

    add_index :retirement_bucket_entries, [ :goal_retirement_id, :account_id ],
      unique: true, name: "index_retirement_bucket_entries_uniqueness"
  end
end
