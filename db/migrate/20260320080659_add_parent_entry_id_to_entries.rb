class AddParentEntryIdToEntries < ActiveRecord::Migration[7.2]
  def change
    add_reference :entries, :parent_entry, type: :uuid, null: true,
      foreign_key: { to_table: :entries, on_delete: :cascade }
  end
end
