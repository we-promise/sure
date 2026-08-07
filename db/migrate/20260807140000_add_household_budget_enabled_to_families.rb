class AddHouseholdBudgetEnabledToFamilies < ActiveRecord::Migration[7.2]
  def change
    # Only meaningful when personal_budgets is true: lets a family keep
    # personal budgets while opting out of the shared household budget.
    add_column :families, :household_budget_enabled, :boolean, default: true, null: false
  end
end
