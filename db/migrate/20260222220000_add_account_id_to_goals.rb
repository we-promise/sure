class AddAccountIdToGoals < ActiveRecord::Migration[7.2]
  def change
    add_reference :goals, :account, type: :uuid, null: true, foreign_key: true
  end
end
