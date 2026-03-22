# frozen_string_literal: true

class BackfillInvestmentContributionCategories < ActiveRecord::Migration[7.2]
  def up
    # PR #924 fixed auto-categorization of investment contributions going forward,
    # but transfers created before that PR have kind = 'investment_contribution'
    # with category_id NULL. This backfill assigns the correct category to those
    # transactions using the family's existing "Investment Contributions" category.
    #
    # Safety:
    # - Only updates transactions where category_id IS NULL (never overwrites user choices)
    # - Only updates transactions that already have kind = 'investment_contribution'
    # - Skips families that don't have an Investment Contributions category yet
    #   (it will be lazily created on their next new transfer)
    # - If a family has duplicate locale-variant categories, picks the oldest one
    #   (matches Family#investment_contributions_category dedup behavior)

    # Static snapshot of Category.all_investment_contributions_names at migration time.
    # Inlined to avoid coupling to app code that may change after this migration ships.
    locale_names = [
      "Investment Contributions",
      "Contributions aux investissements",
      "Contribucions d'inversió",
      "Investeringsbijdragen"
    ]

    quoted_names = locale_names.map { |n| connection.quote(n) }.join(", ")

    say_with_time "Backfilling category for investment_contribution transactions" do
      execute <<-SQL.squish
        UPDATE transactions
        SET category_id = matched_category.id
        FROM entries, accounts,
          LATERAL (
            SELECT c.id
            FROM categories c
            WHERE c.family_id = accounts.family_id
              AND c.name IN (#{quoted_names})
            ORDER BY c.created_at ASC
            LIMIT 1
          ) AS matched_category
        WHERE transactions.kind = 'investment_contribution'
          AND transactions.category_id IS NULL
          AND entries.entryable_id = transactions.id
          AND entries.entryable_type = 'Transaction'
          AND accounts.id = entries.account_id
      SQL
    end
  end

  def down
    # No-op: we cannot distinguish backfilled records from ones that were
    # categorized at creation time, so reverting would incorrectly clear
    # legitimately assigned categories.
  end
end
