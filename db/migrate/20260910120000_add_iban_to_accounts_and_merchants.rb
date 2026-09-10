class AddIbanToAccountsAndMerchants < ActiveRecord::Migration[7.2]
  disable_ddl_transaction!

  ACCOUNTS_INDEX_NAME = "index_accounts_on_family_id_and_iban"
  MERCHANTS_INDEX_NAME = "index_merchants_on_source_and_iban"

  def up
    add_column :accounts, :iban, :string unless column_exists?(:accounts, :iban)
    add_column :merchants, :iban, :string unless column_exists?(:merchants, :iban)

    # CREATE INDEX CONCURRENTLY can't run inside the transaction a normal
    # add_index would use (hence disable_ddl_transaction! above); guard with
    # a validity check, not just index_exists?, since an interrupted
    # concurrent build leaves an INVALID catalog entry that index_exists?
    # would still report as present.
    unless valid_index_exists?(ACCOUNTS_INDEX_NAME)
      execute "DROP INDEX CONCURRENTLY IF EXISTS #{ACCOUNTS_INDEX_NAME}"
      add_index :accounts, [ :family_id, :iban ],
                unique: true,
                where: "(iban IS NOT NULL)",
                name: ACCOUNTS_INDEX_NAME,
                algorithm: :concurrently
    end

    unless valid_index_exists?(MERCHANTS_INDEX_NAME)
      execute "DROP INDEX CONCURRENTLY IF EXISTS #{MERCHANTS_INDEX_NAME}"
      add_index :merchants, [ :source, :iban ],
                unique: true,
                where: "((iban IS NOT NULL) AND ((type)::text = 'ProviderMerchant'::text))",
                name: MERCHANTS_INDEX_NAME,
                algorithm: :concurrently
    end
  end

  def down
    remove_index :merchants, name: MERCHANTS_INDEX_NAME, if_exists: true, algorithm: :concurrently
    remove_index :accounts, name: ACCOUNTS_INDEX_NAME, if_exists: true, algorithm: :concurrently
    remove_column :merchants, :iban, if_exists: true
    remove_column :accounts, :iban, if_exists: true
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
