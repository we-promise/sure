# frozen_string_literal: true

class AddDvfToPropertyAvmProviders < ActiveRecord::Migration[8.1]
  def up
    remove_check_constraint :properties, name: "properties_avm_provider_check"
    add_check_constraint :properties,
      "avm_provider IS NULL OR avm_provider IN ('rentcast', 'realie', 'chimnie', 'dvf')",
      name: "properties_avm_provider_check"
  end

  def down
    # The restored constraint would reject DVF-linked rows, so unlink them
    # first. The accounts and their valuation history are kept.
    execute <<~SQL
      UPDATE properties SET avm_provider = NULL, avm_last_synced_on = NULL
      WHERE avm_provider = 'dvf'
    SQL

    remove_check_constraint :properties, name: "properties_avm_provider_check"
    add_check_constraint :properties,
      "avm_provider IS NULL OR avm_provider IN ('rentcast', 'realie', 'chimnie')",
      name: "properties_avm_provider_check"
  end
end
