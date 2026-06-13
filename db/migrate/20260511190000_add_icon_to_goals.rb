class AddIconToGoals < ActiveRecord::Migration[7.2]
  def change
    add_column :goals, :icon, :string
  end
end
