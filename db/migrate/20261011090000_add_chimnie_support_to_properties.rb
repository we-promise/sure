# frozen_string_literal: true

class AddChimnieSupportToProperties < ActiveRecord::Migration[8.1]
  def up
    # Provider-side identifier for the property (e.g. a UK UPRN for Chimnie).
    add_column :properties, :avm_external_id, :string

    remove_check_constraint :properties, name: "properties_avm_provider_check"
    add_check_constraint :properties,
      "avm_provider IS NULL OR avm_provider IN ('rentcast', 'realie', 'chimnie')",
      name: "properties_avm_provider_check"
  end

  def down
    remove_check_constraint :properties, name: "properties_avm_provider_check"
    add_check_constraint :properties,
      "avm_provider IS NULL OR avm_provider IN ('rentcast', 'realie')",
      name: "properties_avm_provider_check"

    remove_column :properties, :avm_external_id
  end
end
