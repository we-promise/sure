class AddRowsCountToImports < ActiveRecord::Migration[7.2]
  def up
    add_column :imports, :rows_count, :integer, default: 0, null: false

    say_with_time "Backfilling rows_count for imports" do
      Import.reset_column_information
      Import.find_each do |import|
        Import.reset_counters(import.id, :rows)
      end
    end
  end

  def down
    remove_column :imports, :rows_count
  end
end
