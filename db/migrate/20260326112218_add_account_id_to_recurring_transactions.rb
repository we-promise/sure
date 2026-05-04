class AddAccountIdToRecurringTransactions < ActiveRecord::Migration[7.2]
  def up
    # Some long-lived self-hosted instances can already contain duplicate recurring
    # rows because older name-based uniqueness was reflected in schema.rb but was not
    # enforced by a migration on upgraded databases. Deduplicate on the pre-migration
    # shape first so the migration can recover cleanly after a rollback.
    dedupe_recurring_transactions!(
      partition_columns: %w[family_id merchant_id amount currency],
      where_clause: "merchant_id IS NOT NULL"
    )

    dedupe_recurring_transactions!(
      partition_columns: %w[family_id name amount currency],
      where_clause: "merchant_id IS NULL AND name IS NOT NULL"
    )

    add_reference :recurring_transactions, :account, type: :uuid, null: true, foreign_key: true

    # Backfill account_id from the most recent matching entry
    execute <<~SQL
      UPDATE recurring_transactions rt
      SET account_id = subquery.account_id
      FROM (
        SELECT DISTINCT ON (rt2.id) rt2.id AS recurring_transaction_id, e.account_id
        FROM recurring_transactions rt2
        JOIN entries e ON e.entryable_type = 'Transaction'
          AND e.currency = rt2.currency
          AND e.amount = rt2.amount
          AND EXTRACT(DAY FROM e.date) BETWEEN GREATEST(rt2.expected_day_of_month - 2, 1) AND LEAST(rt2.expected_day_of_month + 2, 31)
        JOIN accounts a ON a.id = e.account_id AND a.family_id = rt2.family_id
        LEFT JOIN transactions t ON t.id = e.entryable_id
        WHERE rt2.account_id IS NULL
          AND (
            (rt2.merchant_id IS NOT NULL AND t.merchant_id = rt2.merchant_id)
            OR (rt2.merchant_id IS NULL AND e.name = rt2.name)
          )
        ORDER BY rt2.id, e.date DESC
      ) subquery
      WHERE rt.id = subquery.recurring_transaction_id
    SQL

    # Deduplicate again after backfill because rows that were distinct at the
    # family level can collapse onto the same account-scoped uniqueness key.
    dedupe_recurring_transactions!(
      partition_columns: %w[family_id account_id merchant_id amount currency],
      where_clause: "merchant_id IS NOT NULL"
    )

    dedupe_recurring_transactions!(
      partition_columns: %w[family_id account_id name amount currency],
      where_clause: "merchant_id IS NULL AND name IS NOT NULL"
    )

    # Remove old unique indexes
    remove_index :recurring_transactions, name: "idx_recurring_txns_merchant", if_exists: true
    remove_index :recurring_transactions, name: "idx_recurring_txns_name", if_exists: true

    # Add new unique indexes that include account_id
    add_index :recurring_transactions,
      [ :family_id, :account_id, :merchant_id, :amount, :currency ],
      unique: true,
      where: "merchant_id IS NOT NULL",
      name: "idx_recurring_txns_acct_merchant"

    add_index :recurring_transactions,
      [ :family_id, :account_id, :name, :amount, :currency ],
      unique: true,
      where: "name IS NOT NULL AND merchant_id IS NULL",
      name: "idx_recurring_txns_acct_name"
  end

  def down
    remove_index :recurring_transactions, name: "idx_recurring_txns_acct_merchant", if_exists: true
    remove_index :recurring_transactions, name: "idx_recurring_txns_acct_name", if_exists: true

    add_index :recurring_transactions,
      [ :family_id, :merchant_id, :amount, :currency ],
      unique: true,
      where: "merchant_id IS NOT NULL",
      name: "idx_recurring_txns_merchant"

    add_index :recurring_transactions,
      [ :family_id, :name, :amount, :currency ],
      unique: true,
      where: "name IS NOT NULL AND merchant_id IS NULL",
      name: "idx_recurring_txns_name"

    remove_reference :recurring_transactions, :account
  end

  private

    def dedupe_recurring_transactions!(partition_columns:, where_clause:)
      execute <<~SQL
        WITH ranked AS (
          SELECT id,
                 ROW_NUMBER() OVER (
                   PARTITION BY #{partition_columns.join(', ')}
                   ORDER BY manual DESC,
                            (status = 'active') DESC,
                            last_occurrence_date DESC NULLS LAST,
                            updated_at DESC,
                            id DESC
                 ) AS row_num
          FROM recurring_transactions
          WHERE #{where_clause}
        )
        DELETE FROM recurring_transactions
        WHERE id IN (
          SELECT id FROM ranked WHERE row_num > 1
        )
      SQL
    end
end
