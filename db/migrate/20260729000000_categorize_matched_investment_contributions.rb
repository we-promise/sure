# frozen_string_literal: true

class CategorizeMatchedInvestmentContributions < ActiveRecord::Migration[7.2]
  # Keep this migration independent from the current Category/Family models.
  # The family helper can create, rename, and delete categories, which is not
  # appropriate while a historical data migration is running.
  INVESTMENT_CONTRIBUTION_CATEGORY_NAMES = [
    "Investment Contributions",
    "Contributions aux investissements",
    "Anlagebeiträge",
    "Aportaciones a inversiones",
    "Contributi investimento",
    "Yatırım Katkıları",
    "Contribucions d'inversió",
    "Взносы в инвестиции",
    "Wpłaty inwestycyjne",
    "投資投入金額",
    "投资投入",
    "Investeringsbijdragen",
    "Befektetési befizetések",
    "Đóng góp đầu tư"
  ].freeze

  def up
    quoted_names = INVESTMENT_CONTRIBUTION_CATEGORY_NAMES.map { |name| connection.quote(name) }.join(", ")

    say_with_time "Categorizing confirmed matched investment contributions" do
      execute <<~SQL.squish
        WITH candidates AS (
          SELECT
            transactions.id AS transaction_id,
            matched_categories.id AS category_id
          FROM transactions
          JOIN entries
            ON entries.entryable_id = transactions.id
           AND entries.entryable_type = 'Transaction'
          JOIN accounts ON accounts.id = entries.account_id
          JOIN transfers
            ON transfers.outflow_transaction_id = transactions.id
           AND transfers.status = 'confirmed'
          CROSS JOIN LATERAL (
            SELECT categories.id
            FROM categories
            WHERE categories.family_id = accounts.family_id
              AND categories.name IN (#{quoted_names})
            ORDER BY categories.created_at ASC, categories.id ASC
            LIMIT 1
          ) AS matched_categories
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
        SET updated_at = CURRENT_TIMESTAMP
        WHERE entries.entryable_type = 'Transaction'
          AND entries.entryable_id IN (SELECT id FROM updated_transactions)
      SQL
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
