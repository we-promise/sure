class AddAccountToSavingsGoals < ActiveRecord::Migration[7.2]
  def change
    add_reference :savings_goals, :account, type: :uuid, null: false, foreign_key: true
  end
end
