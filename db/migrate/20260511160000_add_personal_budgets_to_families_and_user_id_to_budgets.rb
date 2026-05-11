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

    add_index :budgets, [:family_id, :start_date, :end_date, :user_id],
              unique: true,
              name: "index_budgets_on_family_start_end_user"
  end
end