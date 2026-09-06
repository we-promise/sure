class AddPlaidPreferOriginalDescriptionToFamilies < ActiveRecord::Migration[8.1]
  def change
    add_column :families, :plaid_prefer_original_description, :boolean, default: false, null: false
  end
end
