class AddTimeToEntries < ActiveRecord::Migration[8.1]
  def change
    add_column :entries, :time, :time
  end
end
