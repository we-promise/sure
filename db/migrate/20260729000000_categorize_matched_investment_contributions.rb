# frozen_string_literal: true

class CategorizeMatchedInvestmentContributions < ActiveRecord::Migration[7.2]
  def up
    Family.find_each do |family|
      scope = Transaction
        .joins(:transfer_as_outflow, entry: :account)
        .where(accounts: { family_id: family.id })
        .where(kind: "investment_contribution", category_id: nil)

      next unless scope.exists?

      category = family.investment_contributions_category
      scope.update_all(category_id: category.id)
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
