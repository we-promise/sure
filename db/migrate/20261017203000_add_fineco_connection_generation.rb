class AddFinecoConnectionGeneration < ActiveRecord::Migration[8.1]
  def change
    add_column :fineco_items, :connection_generation, :integer, null: false, default: 0
  end
end
