# frozen_string_literal: true

class CategorizeMatchedInvestmentContributions < ActiveRecord::Migration[7.2]
  def up
    Family.find_each do |family|
      scope = Transaction
        .joins(:transfer_as_outflow, entry: :account)
        .where(accounts: { family_id: family.id })
        .where(transfers: { status: "confirmed" })
        .where(kind: "investment_contribution", category_id: nil)

      next unless scope.exists?

      # Use an existing category only. This data migration must not create or
      # merge categories as a side effect of backfilling transactions.
      category = family.categories.where(name: Category.all_investment_contributions_names).order(:created_at).first
      next unless category

      entry_ids = scope.pluck("entries.id")
      scope.update_all(category_id: category.id)
      Entry.where(id: entry_ids).update_all(updated_at: Time.current) if entry_ids.any?
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
