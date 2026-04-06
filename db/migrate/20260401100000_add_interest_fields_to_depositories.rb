class AddInterestFieldsToDepositories < ActiveRecord::Migration[7.2]
  def change
    add_column :depositories, :interest_rate, :decimal, precision: 5, scale: 4
    add_column :depositories, :interest_enabled, :boolean, default: false, null: false
  end
end
