class AddDestinationAccountIdToRecurringTransactions < ActiveRecord::Migration[7.2]
  def up
    add_reference :recurring_transactions, :destination_account, type: :uuid, null: true,
                  foreign_key: { to_table: :accounts, on_delete: :cascade }

    # Backfill cascade on the existing account_id FK while we're widening this
    # table -- consistent with the cascading direction set by
    # 20251030172500_add_cascade_on_account_deletes.rb. Without this, deleting
    # an Account that has any recurring_transactions referencing it raises FK
    # violations during Family destruction.
    remove_foreign_key :recurring_transactions, :accounts, column: :account_id
    add_foreign_key :recurring_transactions, :accounts, column: :account_id, on_delete: :cascade

    # Replace the partial unique indexes added by 20260326112218 with TWO
    # predicate-partitioned variants:
    #
    #   * non-transfer rows  (destination_account_id IS NULL) keep the
    #     existing 5-column shape so behaviour is unchanged.
    #   * transfer rows      (destination_account_id IS NOT NULL) get a
    #     6-column variant that includes destination_account_id.
    #
    # We can't simply widen the index because Postgres treats NULLs as
    # distinct in unique indexes, so two non-transfer rows with the same
    # (family, account, merchant/name, amount, currency) but NULL
    # destination would no longer collide.
    remove_index :recurring_transactions, name: "idx_recurring_txns_acct_merchant", if_exists: true
    remove_index :recurring_transactions, name: "idx_recurring_txns_acct_name", if_exists: true

    add_index :recurring_transactions,
      [ :family_id, :account_id, :merchant_id, :amount, :currency ],
      unique: true,
      where: "merchant_id IS NOT NULL AND destination_account_id IS NULL",
      name: "idx_recurring_txns_acct_merchant"

    add_index :recurring_transactions,
      [ :family_id, :account_id, :name, :amount, :currency ],
      unique: true,
      where: "name IS NOT NULL AND merchant_id IS NULL AND destination_account_id IS NULL",
      name: "idx_recurring_txns_acct_name"

    add_index :recurring_transactions,
      [ :family_id, :account_id, :destination_account_id, :merchant_id, :amount, :currency ],
      unique: true,
      where: "destination_account_id IS NOT NULL AND merchant_id IS NOT NULL",
      name: "idx_recurring_txns_pair_merchant"

    add_index :recurring_transactions,
      [ :family_id, :account_id, :destination_account_id, :name, :amount, :currency ],
      unique: true,
      where: "destination_account_id IS NOT NULL AND name IS NOT NULL AND merchant_id IS NULL",
      name: "idx_recurring_txns_pair_name"

    # Enforce transfer invariants in the database alongside the model
    # validations. Per CLAUDE.md: "Enforce null checks, unique indexes,
    # and simple validations in the database schema for PostgreSQL".
    add_check_constraint :recurring_transactions,
      "destination_account_id IS NULL OR account_id IS NOT NULL",
      name: "chk_recurring_txns_transfer_requires_source"

    add_check_constraint :recurring_transactions,
      "destination_account_id IS NULL OR destination_account_id <> account_id",
      name: "chk_recurring_txns_transfer_distinct_accounts"
  end

  def down
    # Transfer rows depend on destination_account_id, which the legacy
    # schema doesn't model. Re-adding the legacy unique indexes after
    # transfer rows exist would violate uniqueness on otherwise-identical
    # (family, account, merchant/name, amount, currency) tuples that
    # differ only by destination, so we drop transfer rows before
    # restoring the old shape. Down migrations are expected to lose
    # feature-specific data; the column itself is removed below anyway.
    execute <<~SQL
      DELETE FROM recurring_transactions
      WHERE destination_account_id IS NOT NULL
    SQL

    remove_check_constraint :recurring_transactions, name: "chk_recurring_txns_transfer_requires_source"
    remove_check_constraint :recurring_transactions, name: "chk_recurring_txns_transfer_distinct_accounts"

    remove_index :recurring_transactions, name: "idx_recurring_txns_pair_merchant", if_exists: true
    remove_index :recurring_transactions, name: "idx_recurring_txns_pair_name", if_exists: true
    remove_index :recurring_transactions, name: "idx_recurring_txns_acct_merchant", if_exists: true
    remove_index :recurring_transactions, name: "idx_recurring_txns_acct_name", if_exists: true

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

    remove_foreign_key :recurring_transactions, :accounts, column: :account_id
    add_foreign_key :recurring_transactions, :accounts, column: :account_id

    # Drop the destination_account_id FK by referencing the actual `accounts`
    # table; Rails would otherwise infer the table as `destination_accounts`
    # (the pluralised reference name) and fail with `no foreign key`.
    remove_foreign_key :recurring_transactions, column: :destination_account_id
    remove_reference :recurring_transactions, :destination_account
  end
end
