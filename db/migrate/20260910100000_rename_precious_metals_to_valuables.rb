class RenamePreciousMetalsToValuables < ActiveRecord::Migration[8.1]
  def up
    rename_table :precious_metals, :valuables
    rename_table :precious_metal_lots, :valuable_items
    rename_column :valuable_items, :precious_metal_id, :valuable_id
    rename_column :valuable_items, :karat, :purity

    remove_check_constraint :valuables, name: "precious_metals_supported_metal"
    remove_column :valuables, :metal_type
    remove_check_constraint :valuable_items, name: "precious_metal_lots_weight_unit"
    remove_check_constraint :valuable_items, name: "precious_metal_lots_karat"
    add_column :valuable_items, :item_type, :string, null: false, default: "bullion"
    add_column :valuable_items, :material, :string, null: false, default: "gold"
    execute "UPDATE valuable_items SET purity = purity * 100 / 24.0 WHERE purity IS NOT NULL"
    add_check_constraint :valuable_items, "weight_unit IN ('gram', 'troy_ounce', 'kilogram', 'carat')", name: "valuable_items_weight_unit"
    add_check_constraint :valuable_items, "purity > 0 AND purity <= 100", name: "valuable_items_purity"
    add_check_constraint :valuable_items, "item_type IN ('bullion', 'gemstone')", name: "valuable_items_item_type"

    execute "UPDATE accounts SET accountable_type = 'Valuable' WHERE accountable_type = 'PreciousMetal'"
    replace_import_mapping_constraints("ValuableItem", from: "PreciousMetalLot")
    execute "UPDATE active_storage_attachments SET record_type = 'ValuableItem' WHERE record_type = 'PreciousMetalLot'"
  end

  def down
    if connection.select_value("SELECT 1 FROM valuable_items WHERE item_type = 'gemstone' LIMIT 1")
      raise ActiveRecord::IrreversibleMigration,
        "Cannot revert Gems and Bullion while gemstone purchases exist. Remove or export those purchases before rolling back."
    end

    execute "UPDATE active_storage_attachments SET record_type = 'PreciousMetalLot' WHERE record_type = 'ValuableItem'"
    replace_import_mapping_constraints("PreciousMetalLot", from: "ValuableItem")
    execute "UPDATE accounts SET accountable_type = 'PreciousMetal' WHERE accountable_type = 'Valuable'"
    remove_check_constraint :valuable_items, name: "valuable_items_item_type"
    remove_check_constraint :valuable_items, name: "valuable_items_purity"
    remove_check_constraint :valuable_items, name: "valuable_items_weight_unit"
    execute "UPDATE valuable_items SET purity = purity * 24 / 100.0 WHERE purity IS NOT NULL"
    remove_column :valuable_items, :material
    remove_column :valuable_items, :item_type
    add_check_constraint :valuable_items, "weight_unit IN ('gram', 'troy_ounce', 'kilogram')", name: "precious_metal_lots_weight_unit"
    add_check_constraint :valuable_items, "purity > 0 AND purity <= 24", name: "precious_metal_lots_karat"
    rename_column :valuable_items, :purity, :karat
    rename_column :valuable_items, :valuable_id, :precious_metal_id
    rename_table :valuable_items, :precious_metal_lots
    rename_table :valuables, :precious_metals
    add_column :precious_metals, :metal_type, :string, null: false, default: "gold"
    add_check_constraint :precious_metals, "metal_type = 'gold'", name: "precious_metals_supported_metal"
  end

  private
    def replace_import_mapping_constraints(type, from:)
      types = %w[Account Category Tag Merchant RecurringTransaction RecurringOccurrence Transaction Budget Security Rule] + [ type ]
      columns = %w[source_type target_type]

      columns.each do |column|
        name = "chk_import_source_mappings_#{column}"
        remove_check_constraint :import_source_mappings, name: name
      end

      columns.each do |column|
        execute "UPDATE import_source_mappings SET #{column} = #{connection.quote(type)} WHERE #{column} = #{connection.quote(from)}"
      end

      columns.each do |column|
        name = "chk_import_source_mappings_#{column}"
        values = types.map { |entry| connection.quote(entry) }.join(", ")
        add_check_constraint :import_source_mappings, "#{column} IN (#{values})", name: name
      end
    end
end
