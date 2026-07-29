# frozen_string_literal: true

class CategorizeMatchedInvestmentContributions < ActiveRecord::Migration[7.2]
  def up
    Family.find_each do |family|
      category = family.investment_contributions_category

      Transaction
        .joins(:transfer_as_outflow, entry: :account)
        .where(accounts: { family_id: family.id })
        .where(kind: "investment_contribution", category_id: nil)
        .update_all(category_id: category.id)
    end
  end

  def down
    # Irreversible data migration: retain the explicit category assignment.
  end
end
