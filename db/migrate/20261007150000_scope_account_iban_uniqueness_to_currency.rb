class ScopeAccountIbanUniquenessToCurrency < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  OLD_INDEX_NAME = "index_accounts_on_family_id_and_iban"
  NEW_INDEX_NAME = "index_accounts_on_family_id_and_iban_and_currency"

  # Revolut and Wise expose one IBAN for several currency sub-accounts, each
  # linked as its own Sure account, so (family_id, iban) alone is too strict.
  def up
    unless valid_index_exists?(NEW_INDEX_NAME)
      execute "DROP INDEX CONCURRENTLY IF EXISTS #{NEW_INDEX_NAME}"
      add_index :accounts, [ :family_id, :iban, :currency ],
                unique: true,
                where: "(iban IS NOT NULL)",
                name: NEW_INDEX_NAME,
                algorithm: :concurrently
    end

    remove_index :accounts, name: OLD_INDEX_NAME, if_exists: true, algorithm: :concurrently
  end

  def down
    # Restoring the stricter index fails while two accounts in a family
    # share an IBAN across currencies; clear one of them first.
    unless valid_index_exists?(OLD_INDEX_NAME)
      execute "DROP INDEX CONCURRENTLY IF EXISTS #{OLD_INDEX_NAME}"
      add_index :accounts, [ :family_id, :iban ],
                unique: true,
                where: "(iban IS NOT NULL)",
                name: OLD_INDEX_NAME,
                algorithm: :concurrently
    end

    remove_index :accounts, name: NEW_INDEX_NAME, if_exists: true, algorithm: :concurrently
  end

  private
    def valid_index_exists?(index_name)
      select_value(<<~SQL.squish) == true
        SELECT indisvalid FROM pg_index
        JOIN pg_class ON pg_class.oid = pg_index.indexrelid
        WHERE pg_class.relname = '#{index_name}'
      SQL
    end
end
