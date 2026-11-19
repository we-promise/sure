class AddFixedReturnToDepositories < ActiveRecord::Migration[7.2]
  def change
    change_table :depositories, bulk: true do |t|
      t.decimal :fixed_return_rate, precision: 10, scale: 3
      t.string :fixed_return_frequency
      t.date :fixed_return_start_date
    end
  end
end
