class AddUpdatedAtIndexesToExchangeRates < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  UPDATED_AT_INDEX = "index_exchange_rates_on_updated_at"
  CURRENCY_UPDATED_AT_INDEX = "index_exchange_rates_on_to_currency_and_updated_at"
  CURRENCY_INDEX = "index_exchange_rates_on_to_currency"

  # Cache keys carry the newest stored exchange rate so a rate that arrives
  # later refreshes the cached totals. ExchangeRate.maximum(:updated_at) runs
  # on every dashboard, report and transactions render (net worth and its
  # breakdown, the income statement, investment totals, transaction search)
  # and, without an index, scans the whole exchange_rates table, which every
  # family shares. These make it, and the budget rollover's per-currency
  # variant, a lookup at the end of an index.
  def up
    add_valid_index UPDATED_AT_INDEX, [ :updated_at ]

    # Replaces the single-column to_currency index: it serves the same
    # to_currency lookups and also ExchangeRate.where(to_currency:).maximum(:updated_at).
    add_valid_index CURRENCY_UPDATED_AT_INDEX, [ :to_currency, :updated_at ]

    # Only drop the old index once its replacement is there and usable, so
    # to_currency lookups never lose their index.
    unless valid_index?(CURRENCY_UPDATED_AT_INDEX)
      raise "#{CURRENCY_UPDATED_AT_INDEX} is missing or invalid; keeping #{CURRENCY_INDEX}"
    end
    remove_index :exchange_rates, name: CURRENCY_INDEX, algorithm: :concurrently, if_exists: true
  end

  def down
    add_valid_index CURRENCY_INDEX, [ :to_currency ]
    remove_index :exchange_rates, name: CURRENCY_UPDATED_AT_INDEX, algorithm: :concurrently, if_exists: true
    remove_index :exchange_rates, name: UPDATED_AT_INDEX, algorithm: :concurrently, if_exists: true
  end

  private
    # CREATE INDEX CONCURRENTLY leaves an INVALID index behind when it's
    # interrupted (a deploy killed mid-build, a timeout). That index still has
    # its name in the catalog, so `if_not_exists` would accept it and the
    # migration would be recorded as done with an index PostgreSQL never uses.
    # Only a valid index counts; an invalid leftover is dropped and rebuilt.
    def add_valid_index(name, columns)
      return if valid_index?(name)

      execute "DROP INDEX CONCURRENTLY IF EXISTS #{quote_table_name(name)}"
      add_index :exchange_rates, columns, name: name, algorithm: :concurrently
    end

    def valid_index?(name)
      select_value(<<~SQL.squish) == true
        SELECT pg_index.indisvalid FROM pg_index
        JOIN pg_class ON pg_class.oid = pg_index.indexrelid
        WHERE pg_class.relname = #{quote(name)}
      SQL
    end
end
