class AddInvestmentContributionsAsSpendingToFamilies < ActiveRecord::Migration[8.1]
  def change
    add_column :families, :investment_contributions_as_spending, :boolean, default: true, null: false
  end
end
