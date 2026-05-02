# Aligns sophtron tables with constraints that PR #596 added to db/schema.rb
# without writing a corresponding migration. Idempotent so envs that already
# match (e.g., those bootstrapped via db:schema:load) re-run cleanly.
class FixSophtronSchemaDrift < ActiveRecord::Migration[7.2]
  disable_ddl_transaction!

  INDEX_NAME = "idx_unique_sophtron_accounts_per_item".freeze

  def up
    unless index_exists?(:sophtron_accounts, [ :sophtron_item_id, :account_id ], unique: true, name: INDEX_NAME)
      add_index :sophtron_accounts,
                [ :sophtron_item_id, :account_id ],
                unique: true,
                name: INDEX_NAME,
                algorithm: :concurrently
    end

    change_column_null :sophtron_items, :user_id, false if column_nullable?(:sophtron_items, :user_id)
    change_column_null :sophtron_items, :access_key, false if column_nullable?(:sophtron_items, :access_key)
  end

  def down
    if index_exists?(:sophtron_accounts, name: INDEX_NAME)
      remove_index :sophtron_accounts, name: INDEX_NAME, algorithm: :concurrently
    end

    change_column_null :sophtron_items, :user_id, true
    change_column_null :sophtron_items, :access_key, true
  end

  private

    def column_nullable?(table, column)
      connection.columns(table).find { |c| c.name == column.to_s }&.null
    end
end
