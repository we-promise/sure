class CreateDebugLogEntries < ActiveRecord::Migration[7.2]
  def up
    create_table :debug_log_entries, id: :uuid do |t|
      t.string :category, null: false
      t.string :level, null: false
      t.text :message, null: false
      t.string :source, null: false
      t.jsonb :metadata, null: false, default: {}
      t.references :family, type: :uuid, foreign_key: { on_delete: :nullify }, null: true
      t.references :account, type: :uuid, foreign_key: { on_delete: :nullify }, null: true
      t.references :user, type: :uuid, foreign_key: { on_delete: :nullify }, null: true
      t.references :account_provider, type: :uuid, foreign_key: { on_delete: :nullify }, null: true
      t.string :provider_key

      t.timestamps
    end

    add_check_constraint :debug_log_entries,
      "level IN ('debug', 'info', 'warn', 'error')",
      name: "chk_debug_log_entries_level"

    add_index :debug_log_entries, :created_at
    add_index :debug_log_entries, :category
    add_index :debug_log_entries, :level
    add_index :debug_log_entries, :source
    add_index :debug_log_entries, :provider_key
    add_index :debug_log_entries, [ :category, :created_at ]
    add_index :debug_log_entries, [ :provider_key, :created_at ]
  end

  def down
    remove_check_constraint :debug_log_entries, name: "chk_debug_log_entries_level", if_exists: true
    drop_table :debug_log_entries
  end
end
