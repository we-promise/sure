class AddTerrascoutxToAvmProviderCheck < ActiveRecord::Migration[8.1]
  def change
    remove_check_constraint :properties,
      "avm_provider IS NULL OR avm_provider IN ('rentcast', 'realie')",
      name: "properties_avm_provider_check"
    add_check_constraint :properties,
      "avm_provider IS NULL OR avm_provider IN ('rentcast', 'realie', 'terrascoutx')",
      name: "properties_avm_provider_check"
  end
end
