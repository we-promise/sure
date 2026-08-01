class AddDisabledModulesToFamilies < ActiveRecord::Migration[7.2]
  def change
    add_column :families, :disabled_modules, :string, array: true, null: false, default: []
  end
end
