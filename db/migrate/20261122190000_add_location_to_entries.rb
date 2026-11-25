class AddLocationToEntries < ActiveRecord::Migration[8.1]
  def change
    add_column :entries, :location_lat, :decimal, precision: 10, scale: 6
    add_column :entries, :location_lng, :decimal, precision: 10, scale: 6
    add_column :entries, :location_name, :string
  end
end
