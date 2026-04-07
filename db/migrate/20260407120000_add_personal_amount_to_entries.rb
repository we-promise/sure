class AddPersonalAmountToEntries < ActiveRecord::Migration[7.2]
  def change
    add_column :entries, :personal_amount, :decimal, precision: 19, scale: 4
  end
end
