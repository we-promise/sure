class AddPersonalBudgetsToFamiliesAndUserIdToBudgets < ActiveRecord::Migration[7.2]
  def change
    add_column :families, :personal_budgets, :boolean, default: false, null: false

    # :optional is not available in all Rails 7.2 versions / setups → use null: true instead
    # on_delete: :nullify allows user deletion without breaking FK constraint
    # (personal budgets become shared/family-level budgets when user is removed)
    add_reference :budgets, :user,
                  type: :uuid,
                  # Use CASCADE to remove personal budgets when the owning user is deleted.
                  # This is appropriate if removing a user should also delete their
                  # personal budgets. Alternatively use :restrict to prevent deletion
                  # until budgets are reassigned. Chosen: :cascade per request.
                  foreign_key: { on_delete: :cascade },
                  null: true

    # Update index to include user_id
    remove_index :budgets, name: "index_budgets_on_family_id_and_start_date_and_end_date"

    # Shared budgets (user_id IS NULL)
    add_index :budgets, [ :family_id, :start_date, :end_date ],
              unique: true,
              where: "user_id IS NULL",
              name: "index_budgets_shared_unique"

    # Personal budgets (user_id IS NOT NULL)
    add_index :budgets, [ :family_id, :start_date, :end_date, :user_id ],
              unique: true,
              where: "user_id IS NOT NULL",
              name: "index_budgets_personal_unique"
  end
end
