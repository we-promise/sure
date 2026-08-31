# frozen_string_literal: true

class CategorizeMatchedInvestmentContributions < ActiveRecord::Migration[7.2]
  # Keep this migration independent from the current Category/Family models.
  # The family helper can create, rename, and delete categories, which is not
  # appropriate while a historical data migration is running.
  def up
    quoted_updated_at = connection.quote(Time.current)

    say_with_time "Categorizing confirmed matched investment contributions" do
      execute <<~SQL.squish
        WITH categorized_categories AS (
          SELECT DISTINCT ON (accounts.family_id)
            accounts.family_id,
            transactions.category_id
          FROM transactions
          JOIN entries
            ON entries.entryable_id = transactions.id
           AND entries.entryable_type = 'Transaction'
          JOIN accounts ON accounts.id = entries.account_id
          JOIN categories ON categories.id = transactions.category_id
          JOIN transfers
            ON transfers.outflow_transaction_id = transactions.id
           AND transfers.status = 'confirmed'
          WHERE transactions.kind = 'investment_contribution'
            AND transactions.category_id IS NOT NULL
            AND categories.family_id = accounts.family_id
          ORDER BY accounts.family_id, categories.created_at ASC, categories.id ASC
        ), keyed_categories AS (
          SELECT DISTINCT ON (categories.family_id)
            categories.family_id,
            categories.id AS category_id
          FROM categories
          WHERE categories.default_key = 'investment_contributions'
          ORDER BY categories.family_id,
                   categories.created_at ASC,
                   categories.id ASC
        ), family_categories AS (
          SELECT family_id, category_id
          FROM categorized_categories
          UNION ALL
          SELECT keyed.family_id, keyed.category_id
          FROM keyed_categories keyed
          WHERE NOT EXISTS (
            SELECT 1
            FROM categorized_categories categorized
            WHERE categorized.family_id = keyed.family_id
          )
        ), candidates AS (
          SELECT
            transactions.id AS transaction_id,
            family_categories.category_id
          FROM transactions
          JOIN entries
            ON entries.entryable_id = transactions.id
           AND entries.entryable_type = 'Transaction'
          JOIN accounts ON accounts.id = entries.account_id
          JOIN transfers
            ON transfers.outflow_transaction_id = transactions.id
           AND transfers.status = 'confirmed'
          JOIN family_categories ON family_categories.family_id = accounts.family_id
          WHERE transactions.kind = 'investment_contribution'
            AND transactions.category_id IS NULL
        ), updated_transactions AS (
          UPDATE transactions
          SET category_id = candidates.category_id
          FROM candidates
          WHERE transactions.id = candidates.transaction_id
          RETURNING transactions.id
        )
        UPDATE entries
        SET updated_at = #{quoted_updated_at}
        WHERE entries.entryable_type = 'Transaction'
          AND entries.entryable_id IN (SELECT id FROM updated_transactions)
      SQL
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
