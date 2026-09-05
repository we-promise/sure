# frozen_string_literal: true

class AddDefaultKeyToCategories < ActiveRecord::Migration[7.2]
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
    add_column :categories, :default_key, :string
    add_index :categories, [ :family_id, :default_key ], unique: true,
      where: "default_key IS NOT NULL",
      name: "index_categories_on_family_id_and_default_key"

    quoted_names = INVESTMENT_CONTRIBUTION_CATEGORY_NAMES.map { |name| connection.quote(name) }.join(", ")

    # Pick one legacy category per family, preserving the same oldest-category
    # behavior as Family#investment_contributions_category without merging or
    # renaming user data during migration.
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

    # A renamed legacy default retains its default visual identity. Only use
    # this fallback when it is unambiguous within a family.
    execute <<~SQL.squish
      WITH candidates AS (
        SELECT (array_agg(id ORDER BY created_at ASC, id ASC))[1] AS id
        FROM categories
        WHERE default_key IS NULL
          AND color = '#0d9488'
          AND lucide_icon = 'trending-up'
          AND parent_id IS NULL
        GROUP BY family_id
        HAVING COUNT(*) = 1
      )
      UPDATE categories
      SET default_key = 'investment_contributions'
      FROM candidates
      WHERE categories.id = candidates.id
    SQL
  end

  def down
    remove_index :categories, name: "index_categories_on_family_id_and_default_key"
    remove_column :categories, :default_key
  end
end
