class AddColorAndIconToPockets < ActiveRecord::Migration[7.2]
  def change
    add_column :pockets, :color, :string
    add_column :pockets, :icon, :string
  end
end
