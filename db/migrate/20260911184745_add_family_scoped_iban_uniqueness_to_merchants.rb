class AddFamilyScopedIbanUniquenessToMerchants < ActiveRecord::Migration[7.2]
  disable_ddl_transaction!

  INDEX_NAME = "index_merchants_on_family_id_and_iban"

  def up
    # On any installation where FamilyMerchant#iban was already writable
    # before this index existed (the parent IBAN-foundation migration, same
    # deploy or earlier), duplicate (family_id, iban) pairs may already be
    # present -- CREATE UNIQUE INDEX CONCURRENTLY aborts outright when they
    # are, leaving an invalid index behind and the migration re-runnable but
    # not self-healing. Fail with a clear, actionable error naming the
    # conflicting merchant ids (not the iban values themselves -- this
    # column is encrypted at rest, and a migration log is not the place to
    # put it back in plaintext) rather than surfacing PostgreSQL's raw
    # unique-violation message.
    conflicting_merchant_ids = select_rows(<<~SQL.squish)
      SELECT ARRAY_AGG(id::text ORDER BY id)
      FROM merchants
      WHERE type = 'FamilyMerchant' AND iban IS NOT NULL
      GROUP BY family_id, iban
      HAVING COUNT(*) > 1
    SQL

    if conflicting_merchant_ids.any?
      ids = conflicting_merchant_ids.flat_map { |row| row.first.tr("{}", "").split(",") }
      raise "Cannot add the family-scoped iban uniqueness index: " \
            "FamilyMerchant rows #{ids.join(', ')} already share an iban within " \
            "the same family. Resolve the duplicates (merge or clear iban on " \
            "all but one per group) before re-running this migration."
    end

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
