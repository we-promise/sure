class AddRetirementParamsToGoals < ActiveRecord::Migration[7.2]
  def change
    add_column :goals, :retirement_params, :jsonb, default: {}, null: false
  end
end
