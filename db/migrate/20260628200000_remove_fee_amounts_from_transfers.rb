class RemoveFeeAmountsFromTransfers < ActiveRecord::Migration[7.2]
  def change
    remove_check_constraint :transfers, name: "check_source_fee_non_negative"
    remove_check_constraint :transfers, name: "check_destination_fee_non_negative"
    remove_column :transfers, :source_fee_amount, :decimal
    remove_column :transfers, :destination_fee_amount, :decimal
  end
end
