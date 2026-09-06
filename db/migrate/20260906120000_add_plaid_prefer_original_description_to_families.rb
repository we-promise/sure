class AddPlaidPreferOriginalDescriptionToFamilies < ActiveRecord::Migration[7.2]
  def change
    add_column :families, :plaid_prefer_original_description, :boolean, default: false, null: false
  end
end
