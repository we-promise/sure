class AddAutoMatchTransfersDisabledToFamilies < ActiveRecord::Migration[7.2]
  def change
    add_column :families, :auto_match_transfers_disabled, :boolean, default: false, null: false
  end
end
