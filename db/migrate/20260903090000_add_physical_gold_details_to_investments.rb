class AddPhysicalGoldDetailsToInvestments < ActiveRecord::Migration[8.0]
  def change
    change_table :investments, bulk: true do |t|
      t.decimal :gold_weight, precision: 18, scale: 6
      t.string :gold_weight_unit
      t.decimal :gold_karat, precision: 4, scale: 1
      t.decimal :gold_manual_value, precision: 18, scale: 2
    end
  end
end
