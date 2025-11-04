class AddExternalIdAndSourceToEntries < ActiveRecord::Migration[7.2]
  def change
    add_column :entries, :external_id, :string
    add_column :entries, :source, :string

    # Add unique index on external_id + source combination to prevent duplicates
    add_index :entries, [ :external_id, :source ], unique: true, where: "external_id IS NOT NULL AND source IS NOT NULL"
  end
end
