# frozen_string_literal: true

class CategorizeMatchedInvestmentContributions < ActiveRecord::Migration[7.2]
  # Keep this migration independent from the current Category/Family models.
  # The family helper can create, rename, and delete categories, which is not
  # appropriate while a historical data migration is running.
  # Snapshot of the category's display names at migration authoring time. The
  # supported locales nb, pt-BR, and ro currently fall back to English for this
  # key, so their label is intentionally represented by "Investment Contributions".
  # Keep this list static: replaying a historical migration must not depend on
  # today's I18n files or Category model behavior.
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
    "Đóng góp đầu tư",
    "Інвестиційні внески",
    "Внески в інвестиції"
  ].freeze
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
        ), named_categories AS (
          SELECT DISTINCT ON (categories.family_id)
            categories.family_id,
            categories.id AS category_id
          FROM categories
          WHERE categories.default_key = 'investment_contributions'
             OR categories.name IN (#{quoted_names})
          ORDER BY categories.family_id,
                   (categories.default_key = 'investment_contributions') DESC,
                   categories.created_at ASC,
                   categories.id ASC
        ), family_categories AS (
          SELECT family_id, category_id
          FROM categorized_categories
          UNION ALL
          SELECT named.family_id, named.category_id
          FROM named_categories named
          WHERE NOT EXISTS (
            SELECT 1
            FROM categorized_categories categorized
            WHERE categorized.family_id = named.family_id
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
