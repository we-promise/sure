class CreateSavingsContributions < ActiveRecord::Migration[7.2]
  def change
    create_table :savings_contributions, id: :uuid do |t|
      t.references :savings_goal, null: false, foreign_key: true, type: :uuid
      t.references :budget, foreign_key: true, type: :uuid
      t.decimal :amount, precision: 19, scale: 4, null: false
      t.string :currency, null: false
      t.string :source, null: false
      t.text :notes
      t.date :contributed_at, null: false

      t.timestamps
    end

    # At most one auto-funded contribution per (goal, budget) pair.
    # Manual and initial contributions are unconstrained.
    add_index :savings_contributions,
              [ :savings_goal_id, :budget_id ],
              unique: true,
              where: "source = 'auto'",
              name: "index_auto_contributions_unique_per_goal_per_budget"
  end
end
