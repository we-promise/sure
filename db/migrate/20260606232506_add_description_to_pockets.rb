class AddDescriptionToPockets < ActiveRecord::Migration[7.2]
  def change
    add_column :pockets, :description, :string
  end
end
