class AddAvmProviderCheckToProperties < ActiveRecord::Migration[7.2]
  def change
    add_check_constraint :properties,
      "avm_provider IS NULL OR avm_provider IN ('rentcast', 'realie')",
      name: "properties_avm_provider_check"
  end
end
