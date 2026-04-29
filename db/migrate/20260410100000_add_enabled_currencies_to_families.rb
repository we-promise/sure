class AddEnabledCurrenciesToFamilies < ActiveRecord::Migration[7.2]
  def change
    add_column :families, :enabled_currencies, :string, array: true
  end
end
