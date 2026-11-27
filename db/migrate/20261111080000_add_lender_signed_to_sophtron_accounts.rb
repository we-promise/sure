class AddLenderSignedToSophtronAccounts < ActiveRecord::Migration[8.1]
  def change
    add_column :sophtron_accounts, :lender_signed, :boolean
  end
end
