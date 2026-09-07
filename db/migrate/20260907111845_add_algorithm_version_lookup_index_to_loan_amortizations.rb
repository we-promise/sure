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

  def change
    add_index :loan_amortizations,
              [ :algorithm_version, :loan_id ],
              name: "index_loan_amortizations_on_algorithm_version_and_loan_id",
              algorithm: :concurrently
  end
end
