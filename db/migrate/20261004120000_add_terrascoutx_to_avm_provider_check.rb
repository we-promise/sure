class AddTerrascoutxToAvmProviderCheck < ActiveRecord::Migration[8.1]
  def up
    remove_check_constraint :properties,
      "avm_provider IS NULL OR avm_provider IN ('rentcast', 'realie')",
      name: "properties_avm_provider_check"
    add_check_constraint :properties,
      "avm_provider IS NULL OR avm_provider IN ('rentcast', 'realie', 'terrascoutx')",
      name: "properties_avm_provider_check"
  end

  # The old constraint would reject any property already set to 'terrascoutx', so rollback stops while one exists.
  # Clear those values first (set avm_provider to NULL; the valuation itself is kept elsewhere). The scan is a full
  # pass over properties, since avm_provider has no index.
  def down
    if select_value("SELECT 1 FROM properties WHERE avm_provider = 'terrascoutx' LIMIT 1")
      raise ActiveRecord::MigrationError, "properties still have avm_provider = 'terrascoutx'; set them to NULL before rolling back"
    end

    remove_check_constraint :properties,
      "avm_provider IS NULL OR avm_provider IN ('rentcast', 'realie', 'terrascoutx')",
      name: "properties_avm_provider_check"
    add_check_constraint :properties,
      "avm_provider IS NULL OR avm_provider IN ('rentcast', 'realie')",
      name: "properties_avm_provider_check"
  end
end
