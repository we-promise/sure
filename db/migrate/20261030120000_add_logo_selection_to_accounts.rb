# Which icon an account shows. "automatic" is the stored logo, then the
# Brandfetch one, then the provider's; any other value is a source the user
# chose over the stored logo, which is kept to switch back to. A string, so a
# new URL-based source needs no schema change.
class AddLogoSelectionToAccounts < ActiveRecord::Migration[8.1]
  def change
    add_column :accounts, :logo_selection, :string, default: "automatic", null: false
  end
end
