# frozen_string_literal: true

class AddInvestmentContributionReportingSupport < ActiveRecord::Migration[8.1]
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
    "Внески в інвестиції",
    "Contribuições para Investimentos"
  ].freeze

  def up
    add_column :categories, :default_key, :string
    add_index :categories, [ :family_id, :default_key ], unique: true,
      where: "default_key IS NOT NULL",
      name: "index_categories_on_family_id_and_default_key"
    add_column :families, :treat_investment_contributions_as_transfers, :boolean, null: false, default: false

    quoted_names = INVESTMENT_CONTRIBUTION_CATEGORY_NAMES.map { |name| connection.quote(name) }.join(", ")
    execute <<~SQL.squish
      WITH candidates AS (
        SELECT (array_agg(id ORDER BY created_at ASC, id ASC))[1] AS id
        FROM categories
        WHERE name IN (#{quoted_names})
        GROUP BY family_id
      )
      UPDATE categories
      SET default_key = 'investment_contributions'
      FROM candidates
      WHERE categories.id = candidates.id
    SQL

    execute <<~SQL.squish
      WITH candidates AS (
        SELECT (array_agg(id ORDER BY created_at ASC, id ASC))[1] AS id
        FROM categories
        WHERE default_key IS NULL
          AND color = '#0d9488'
          AND lucide_icon = 'trending-up'
          AND parent_id IS NULL
          AND NOT EXISTS (
            SELECT 1 FROM categories keyed
            WHERE keyed.family_id = categories.family_id
              AND keyed.default_key = 'investment_contributions'
          )
          AND EXISTS (
            SELECT 1
            FROM transactions
            JOIN transfers ON transfers.outflow_transaction_id = transactions.id
              AND transfers.status = 'confirmed'
            WHERE transactions.category_id = categories.id
              AND transactions.kind = 'investment_contribution'
          )
        GROUP BY family_id
        HAVING COUNT(*) = 1
      )
      UPDATE categories
      SET default_key = 'investment_contributions'
      FROM candidates
      WHERE categories.id = candidates.id
    SQL

    backfill_confirmed_matches
  end

  # Regression tests can exercise the data step against the current schema.
  def backfill_confirmed_matches
    quoted_updated_at = connection.quote(Time.current)
    say_with_time "Categorizing confirmed matched investment contributions" do
      execute <<~SQL.squish
        WITH categorized_categories AS (
          SELECT DISTINCT ON (accounts.family_id)
            accounts.family_id, transactions.category_id
          FROM transactions
          JOIN entries ON entries.entryable_id = transactions.id
            AND entries.entryable_type = 'Transaction'
          JOIN accounts ON accounts.id = entries.account_id
          JOIN categories ON categories.id = transactions.category_id
          JOIN transfers ON transfers.outflow_transaction_id = transactions.id
            AND transfers.status = 'confirmed'
          WHERE transactions.kind = 'investment_contribution'
            AND transactions.category_id IS NOT NULL
            AND categories.family_id = accounts.family_id
          ORDER BY accounts.family_id, categories.created_at ASC, categories.id ASC
        ), keyed_categories AS (
          SELECT DISTINCT ON (family_id) family_id, id AS category_id
          FROM categories
          WHERE default_key = 'investment_contributions'
          ORDER BY family_id, created_at ASC, id ASC
        ), family_categories AS (
          SELECT family_id, category_id FROM categorized_categories
          UNION ALL
          SELECT keyed.family_id, keyed.category_id FROM keyed_categories keyed
          WHERE NOT EXISTS (
            SELECT 1 FROM categorized_categories categorized
            WHERE categorized.family_id = keyed.family_id
          )
        ), candidates AS (
          SELECT transactions.id AS transaction_id, family_categories.category_id
          FROM transactions
          JOIN entries ON entries.entryable_id = transactions.id
            AND entries.entryable_type = 'Transaction'
          JOIN accounts ON accounts.id = entries.account_id
          JOIN transfers ON transfers.outflow_transaction_id = transactions.id
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
    # The category assignments made by backfill_confirmed_matches cannot be
    # reconstructed safely during rollback. Treat the migration as
    # irreversible rather than removing the schema columns while leaving the
    # data change in place.
    raise ActiveRecord::IrreversibleMigration
  end
end
