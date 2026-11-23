class CreatePageCacheEntries < ActiveRecord::Migration[8.1]
  def change
    create_table :page_cache_entries, id: :uuid do |t|
      t.references :family, null: false, foreign_key: { on_delete: :cascade }, type: :uuid
      t.string :page_key, null: false
      t.integer :bytes, null: false
      t.datetime :last_used_at, null: false
      t.timestamps
    end

    add_index :page_cache_entries, :page_key, unique: true
    add_index :page_cache_entries, :last_used_at
  end
end
