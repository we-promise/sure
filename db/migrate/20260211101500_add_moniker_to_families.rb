class AddMonikerToFamilies < ActiveRecord::Migration[7.2]
  def change
    add_column :families, :moniker, :string, null: false, default: "Family"
  end
end
