# frozen_string_literal: true

class CreateBudgetPlans < ActiveRecord::Migration[7.2]
  def up
    create_table :budget_plans, id: :uuid do |t|
      t.references :family, null: false, foreign_key: { on_delete: :cascade }, type: :uuid
      t.string :name, null: false
      t.string :slug, null: false
      t.boolean :is_default, null: false, default: false

      t.timestamps
    end

    add_index :budget_plans, [ :family_id, :slug ], unique: true
    add_index :budget_plans, :family_id, unique: true, where: "is_default",
              name: "index_budget_plans_one_default_per_family"

    create_table :budget_plan_accounts, id: :uuid do |t|
      t.references :budget_plan, null: false, foreign_key: { on_delete: :cascade }, type: :uuid
      t.references :account, null: false, foreign_key: { on_delete: :cascade }, type: :uuid

      t.timestamps
    end

    add_index :budget_plan_accounts, [ :budget_plan_id, :account_id ], unique: true,
              name: "index_budget_plan_accounts_on_plan_and_account"

    add_column :budgets, :budget_plan_id, :uuid
    add_foreign_key :budgets, :budget_plans

    # One default plan per family that already has budgets; existing budgets attach to it.
    execute <<~SQL
      INSERT INTO budget_plans (id, family_id, name, slug, is_default, created_at, updated_at)
      SELECT gen_random_uuid(), family_id, 'Primary', 'primary', true, NOW(), NOW()
      FROM budgets
      GROUP BY family_id
    SQL

    execute <<~SQL
      UPDATE budgets
      SET budget_plan_id = budget_plans.id
      FROM budget_plans
      WHERE budget_plans.family_id = budgets.family_id AND budget_plans.is_default
    SQL

    change_column_null :budgets, :budget_plan_id, false
    add_index :budgets, [ :budget_plan_id, :start_date, :end_date ], unique: true,
              name: "index_budgets_on_plan_and_start_date_and_end_date"
    remove_index :budgets, name: "index_budgets_on_family_id_and_start_date_and_end_date"
  end

  def down
    # Sibling plans can hold budgets for the same family and period, which the
    # former (family_id, start_date, end_date) unique index cannot represent.
    raise ActiveRecord::IrreversibleMigration
  end
end
