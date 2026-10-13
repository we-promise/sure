class AddExchangeRatesUpdatedAtIndex < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  INDEX_NAME = "index_exchange_rates_on_updated_at"

  # IncomeStatement#cache_freshness_key reads ExchangeRate.maximum(:updated_at)
  # over the whole table on every dashboard, report and budget render.
  def up
    # See AddEntriesEntryableIndex: keep a valid index, rebuild an invalid one.
    return if valid_index_exists?

    execute "DROP INDEX CONCURRENTLY IF EXISTS #{INDEX_NAME}"

    add_index :exchange_rates, :updated_at,
              name: INDEX_NAME,
              algorithm: :concurrently
  end

  def down
    remove_index :exchange_rates, name: INDEX_NAME, if_exists: true, algorithm: :concurrently
  end

  private
    def valid_index_exists?
      select_value(<<~SQL.squish) == true
        SELECT indisvalid FROM pg_index
        JOIN pg_class ON pg_class.oid = pg_index.indexrelid
        WHERE pg_class.relname = '#{INDEX_NAME}'
      SQL
    end
end
