class AddCashSubgroupEnabledToFamilies < ActiveRecord::Migration[7.2]
  def change
    add_column :families, :cash_subgroup_enabled, :boolean, null: false, default: true
  end
end
