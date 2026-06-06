class AddTrigramIndexForTransactionNameSuggestions < ActiveRecord::Migration[7.2]
  disable_ddl_transaction!

  def change
    add_index :entries,
              "lower(regexp_replace(trim(name), ' +', ' ', 'g')) gin_trgm_ops",
              name: "index_entries_on_normalized_name_for_transaction_suggestions",
              using: :gin,
              algorithm: :concurrently,
              if_not_exists: true,
              where: "entryable_type = 'Transaction' AND parent_entry_id IS NULL AND name IS NOT NULL AND name != ''"
  end
end
