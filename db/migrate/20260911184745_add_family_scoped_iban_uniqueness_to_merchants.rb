class AddFamilyScopedIbanUniquenessToMerchants < ActiveRecord::Migration[7.2]
  disable_ddl_transaction!

  INDEX_NAME = "index_merchants_on_family_id_and_iban"

  def up
    # Without this, two FamilyMerchant rows in the same family could share
    # an IBAN (nothing enforced it), so find_by(iban:) in
    # Account::ProviderImportAdapter#find_or_create_merchant would pick an
    # unspecified one -- assigning a future Enable Banking transaction to
    # the wrong family-configured merchant regardless of its name.
    unless valid_index_exists?(INDEX_NAME)
      execute "DROP INDEX CONCURRENTLY IF EXISTS #{INDEX_NAME}"
      add_index :merchants, [ :family_id, :iban ],
                unique: true,
                where: "((iban IS NOT NULL) AND ((type)::text = 'FamilyMerchant'::text))",
                name: INDEX_NAME,
                algorithm: :concurrently
    end
  end

  def down
    remove_index :merchants, name: INDEX_NAME, if_exists: true, algorithm: :concurrently
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
