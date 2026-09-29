class AddPersonalBudgets < ActiveRecord::Migration[7.2]
  def up
    add_column :families, :personal_budgets, :boolean, default: false, null: false
    add_column :families, :household_budget_enabled, :boolean, default: true, null: false

    add_reference :budgets,
                  :user,
                  type: :uuid,
                  foreign_key: { on_delete: :cascade },
                  null: true

    remove_index :budgets, name: "index_budgets_on_family_id_and_start_date_and_end_date"

    add_index :budgets,
              [ :family_id, :start_date, :end_date ],
              unique: true,
              where: "user_id IS NULL",
              name: "index_budgets_shared_unique"

    add_index :budgets,
              [ :family_id, :start_date, :end_date, :user_id ],
              unique: true,
              where: "user_id IS NOT NULL",
              name: "index_budgets_personal_unique"

    remove_foreign_key :budget_categories, :budgets
    add_foreign_key :budget_categories, :budgets, on_delete: :cascade

    create_table :budget_shares, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :owner, type: :uuid, null: false, foreign_key: { to_table: :users }
      t.references :viewer, type: :uuid, null: false, foreign_key: { to_table: :users }
      t.string :permission, null: false, default: "read_only"
      t.timestamps
    end

    add_index :budget_shares, [ :owner_id, :viewer_id ], unique: true
  end

  def down
    drop_table :budget_shares

    remove_foreign_key :budget_categories, :budgets
    add_foreign_key :budget_categories, :budgets

    remove_index :budgets, name: "index_budgets_personal_unique"
    remove_index :budgets, name: "index_budgets_shared_unique"

    add_index :budgets,
              [ :family_id, :start_date, :end_date ],
              unique: true,
              name: "index_budgets_on_family_id_and_start_date_and_end_date"

    remove_reference :budgets, :user, type: :uuid, foreign_key: true

    remove_column :families, :household_budget_enabled
    remove_column :families, :personal_budgets
  end
end
