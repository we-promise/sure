class AddRequireTransferMatchConfirmationToFamilies < ActiveRecord::Migration[8.1]
  def change
    add_column :families, :require_transfer_match_confirmation, :boolean, default: false, null: false
  end
end
