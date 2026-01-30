class AddUniqueIndexToSavingContributions < ActiveRecord::Migration[7.2]
  def change
    add_index :saving_contributions, [:saving_goal_id, :month], unique: true, where: "source = 'auto'", name: "index_unique_auto_contributions"
  end
end
