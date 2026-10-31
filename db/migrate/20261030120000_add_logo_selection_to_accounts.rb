# Which icon an account shows: "automatic" is the stored logo, then the
# Brandfetch one, then the provider's; "brandfetch" shows Brandfetch over the
# stored logo, which is kept to switch back to. The enum in Account::Logoable
# lists the values; a string, so a new source needs no schema change.
class AddLogoSelectionToAccounts < ActiveRecord::Migration[8.1]
  def change
    add_column :accounts, :logo_selection, :string, default: "automatic", null: false
  end
end
