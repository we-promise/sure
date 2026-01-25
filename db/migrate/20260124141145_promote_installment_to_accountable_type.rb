class PromoteInstallmentToAccountableType < ActiveRecord::Migration[7.2]
  def up
    # Step 1: Update classification generated column
    # Use a single DDL statement to avoid a window where classification queries fail
    execute <<-SQL
      ALTER TABLE accounts
        DROP COLUMN classification,
        ADD COLUMN classification text GENERATED ALWAYS AS (
          CASE
            WHEN accountable_type IN ('Loan', 'CreditCard', 'OtherLiability', 'Installment')
            THEN 'liability'
            ELSE 'asset'
          END
        ) STORED;
    SQL

    # Step 2: Safety assertion — each account should have at most 1 installment
    result = execute(<<-SQL)
      SELECT COUNT(*) as cnt FROM (
        SELECT account_id, COUNT(*) as c
        FROM installments
        GROUP BY account_id
        HAVING COUNT(*) > 1
      ) dupes;
    SQL
    count = result.first["cnt"].to_i
    raise "Found accounts with multiple installments — fix data first" if count > 0

    # Step 3: Data migration — convert installment-mode loans to new type
    # (while account_id FK still exists on installments table)
    execute <<-SQL
      UPDATE accounts
      SET accountable_type = 'Installment',
          accountable_id = installments.id,
          subtype = NULL
      FROM installments
      WHERE installments.account_id = accounts.id
        AND accounts.accountable_type = 'Loan'
        AND accounts.subtype = 'installment';
    SQL

    # Step 4: Clean up orphaned Loan records
    execute <<-SQL
      DELETE FROM loans
      WHERE NOT EXISTS (
        SELECT 1 FROM accounts
        WHERE accounts.accountable_type = 'Loan'
          AND accounts.accountable_id = loans.id
      );
    SQL

    # Step 5: Restructure installments table for accountable pattern
    remove_foreign_key :installments, :accounts
    remove_index :installments, :account_id
    remove_column :installments, :account_id, :uuid
    add_column :installments, :subtype, :string
    add_column :installments, :locked_attributes, :jsonb, default: {}
  end

  def down
    # Add account_id back
    add_reference :installments, :account, type: :uuid, index: true
    remove_column :installments, :subtype
    remove_column :installments, :locked_attributes

    # Repopulate account_id from accounts table
    execute <<-SQL
      UPDATE installments
      SET account_id = accounts.id
      FROM accounts
      WHERE accounts.accountable_type = 'Installment'
        AND accounts.accountable_id = installments.id;
    SQL

    # Add foreign key back (after data is populated)
    add_foreign_key :installments, :accounts

    # Revert accountable_type back to Loan
    execute <<-SQL
      UPDATE accounts
      SET accountable_type = 'Loan',
          subtype = 'installment'
      WHERE accountable_type = 'Installment';
    SQL

    # Restore classification column without Installment
    execute <<-SQL
      ALTER TABLE accounts
        DROP COLUMN classification,
        ADD COLUMN classification text GENERATED ALWAYS AS (
          CASE
            WHEN accountable_type IN ('Loan', 'CreditCard', 'OtherLiability')
            THEN 'liability'
            ELSE 'asset'
          END
        ) STORED;
    SQL
  end
end
