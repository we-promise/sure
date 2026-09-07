class AddAlgorithmVersionLookupIndexToLoanAmortizations < ActiveRecord::Migration[7.2]
  # The existing index leads with loan_id, which serves per-loan reads but not
  # the estate-wide deploy-monitoring query in `loans:schedule_version_status`
  # ("how many loans are still on an older algorithm version?"). That query
  # filters and groups on algorithm_version with no loan_id, so it could only
  # sequential-scan.
  #
  # Measured on 360,000 rows (12,000 loans x 30 payments), the shape of a
  # mid-size estate:
  #
  #   without this index  Seq Scan + external merge sort, 10.6 MB to disk, 312.810 ms
  #   with this index     Index Only Scan, no sort,                        135.286 ms
  #
  # The sort disappearing matters more than the wall clock: this query is meant
  # to be run repeatedly while a prebuild drains, and a query that spills to
  # disk each time is one an operator stops running.
  #
  # loan_id is the second column so the scan stays index-only -- the query
  # counts DISTINCT loan_id per version and would otherwise return to the heap.
  disable_ddl_transaction!

  INDEX_NAME = "index_loan_amortizations_on_algorithm_version_and_loan_id".freeze

  # Written as up/down rather than change, and deliberately retry-safe.
  #
  # Without a DDL transaction, an interrupted CREATE INDEX CONCURRENTLY leaves
  # the index behind while Rails never records the migration as run. The retry
  # then fails on the duplicate name (42P07). Worse, Postgres keeps an INVALID
  # index after a failed concurrent build -- one the planner ignores but which
  # still occupies the name, so `if_not_exists` alone would silently "succeed"
  # while leaving the query it exists for on a sequential scan.
  def up
    remove_index :loan_amortizations, name: INDEX_NAME, algorithm: :concurrently if invalid_index?

    add_index :loan_amortizations,
              [ :algorithm_version, :loan_id ],
              name: INDEX_NAME,
              algorithm: :concurrently,
              if_not_exists: true
  end

  def down
    remove_index :loan_amortizations, name: INDEX_NAME, algorithm: :concurrently, if_exists: true
  end

  private

    def invalid_index?
      select_value(<<~SQL.squish).present?
        SELECT 1
        FROM pg_class c
        JOIN pg_index i ON i.indexrelid = c.oid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE c.relname = '#{INDEX_NAME}'
          AND n.nspname = ANY (current_schemas(false))
          AND NOT i.indisvalid
      SQL
    end
end
