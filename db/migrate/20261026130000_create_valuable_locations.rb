# Where Gems and Bullion items are kept (a home safe, a bank vault). Locations
# belong to the family so items in different accounts can share them, and
# valuable_item_moves records each change of location.
class CreateValuableLocations < ActiveRecord::Migration[8.1]
  def change
    create_table :valuable_locations, id: :uuid do |t|
      t.references :family, type: :uuid, null: false, foreign_key: true
      t.string :name, null: false
      t.timestamps
    end
    add_index :valuable_locations, "family_id, lower(name)", unique: true, name: "index_valuable_locations_on_family_and_lower_name"
    add_check_constraint :valuable_locations, "btrim(name::text) <> ''::text", name: "valuable_locations_name_present"

    add_reference :valuable_items, :location, type: :uuid, foreign_key: { to_table: :valuable_locations, on_delete: :nullify }

    create_table :valuable_item_moves, id: :uuid do |t|
      t.references :valuable_item, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :from_location, type: :uuid, foreign_key: { to_table: :valuable_locations, on_delete: :nullify }
      t.references :to_location, type: :uuid, foreign_key: { to_table: :valuable_locations, on_delete: :nullify }
      t.date :moved_on, null: false
      t.timestamps
    end
  end
end
