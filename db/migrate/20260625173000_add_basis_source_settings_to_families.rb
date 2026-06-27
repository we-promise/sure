class AddBasisSourceSettingsToFamilies < ActiveRecord::Migration[7.2]
  def change
    add_column :families, :basis_long_address, :string
    add_column :families, :basis_long_token_addresses, :text
    add_column :families, :basis_lighter_address, :string
  end
end
