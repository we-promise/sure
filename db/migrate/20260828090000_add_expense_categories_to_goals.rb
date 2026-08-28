# A reserve sized in months of expenses can now be told WHICH expenses count.
# Selecting none keeps the previous meaning — every expense — so existing
# reserves need no backfill and nothing changes for them.
class AddExpenseCategoriesToGoals < ActiveRecord::Migration[7.2]
  def change
    create_table :goal_expense_categories, id: :uuid do |t|
      t.references :goal, null: false, foreign_key: true, type: :uuid
      t.references :category, null: false, foreign_key: true, type: :uuid
      t.timestamps
    end

    add_index :goal_expense_categories, [ :goal_id, :category_id ], unique: true

    # Only consulted when a selection exists: with none, everything counts and
    # uncategorised spending is already in.
    add_column :goals, :include_uncategorized_expenses, :boolean, default: false, null: false
  end
end
