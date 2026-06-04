class AddFeesToTransfers < ActiveRecord::Migration[7.2]
  def change
    add_column :transfers, :source_fee_amount, :decimal, precision: 19, scale: 4, null: false, default: 0
    add_column :transfers, :destination_fee_amount, :decimal, precision: 19, scale: 4, null: false, default: 0

    add_check_constraint :transfers, "source_fee_amount >= 0", name: "check_source_fee_non_negative"
    add_check_constraint :transfers, "destination_fee_amount >= 0", name: "check_destination_fee_non_negative"
  end
end
