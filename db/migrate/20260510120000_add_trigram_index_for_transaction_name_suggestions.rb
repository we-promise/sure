class AddTrigramIndexForTransactionNameSuggestions < ActiveRecord::Migration[7.0]
  def change
    enable_extension :pg_trgm unless extension_enabled?('pg_trgm')

    add_index :entries,
              "lower(regexp_replace(trim(name), '\s+', ' ', 'g')) gin_trgm_ops",
              name: 'index_entries_on_normalized_name_for_transaction_suggestions',
              using: :gin,
              where: "entryable_type = 'Transaction' AND parent_entry_id IS NULL AND name IS NOT NULL AND name != ''"
  end
end