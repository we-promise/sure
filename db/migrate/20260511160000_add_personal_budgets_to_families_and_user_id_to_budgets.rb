class AddPersonalBudgetsToFamiliesAndUserIdToBudgets < ActiveRecord::Migration[7.2]
  def change
    add_column :families, :personal_budgets, :boolean, default: false, null: false

    # :optional is not available in all Rails 7.2 versions / setups → use null: true instead
    add_reference :budgets, :user,
                  type: :uuid,
                  foreign_key: true,
                  null: true

    # Update index to include user_id
    remove_index :budgets, name: "index_budgets_on_family_id_and_start_date_and_end_date"

    # Shared budgets (user_id IS NULL)
    add_index :budgets, [:family_id, :start_date, :end_date],
              unique: true,
              where: "user_id IS NULL",
              name: "index_budgets_shared_unique"

    # Personal budgets (user_id IS NOT NULL)
    add_index :budgets, [:family_id, :start_date, :end_date, :user_id],
              unique: true,
              where: "user_id IS NOT NULL",
              name: "index_budgets_personal_unique"
  end
end
