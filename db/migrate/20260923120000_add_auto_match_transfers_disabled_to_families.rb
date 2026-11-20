class AddAutoMatchTransfersDisabledToFamilies < ActiveRecord::Migration[8.1]
  def change
    add_column :families, :auto_match_transfers_disabled, :boolean, default: false, null: false
  end
end
