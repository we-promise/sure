class AddRetirementDisabledToFamilies < ActiveRecord::Migration[7.2]
  def change
    add_column :families, :retirement_disabled, :boolean, default: false, null: false
  end
end
