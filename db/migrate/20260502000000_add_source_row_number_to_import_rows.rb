class AddSourceRowNumberToImportRows < ActiveRecord::Migration[7.2]
  def up
    add_column :import_rows, :source_row_number, :integer

    execute <<~SQL
      WITH numbered AS (
        SELECT id,
               ROW_NUMBER() OVER (PARTITION BY import_id ORDER BY created_at, id) AS row_number
        FROM import_rows
      )
      UPDATE import_rows
      SET source_row_number = numbered.row_number
      FROM numbered
      WHERE import_rows.id = numbered.id
    SQL

    change_column_null :import_rows, :source_row_number, false
    add_check_constraint :import_rows, "source_row_number > 0", name: "chk_import_rows_source_row_number_positive"
    add_index :import_rows, [ :import_id, :source_row_number ], unique: true, name: "index_import_rows_on_import_id_and_source_row_number"
  end

  def down
    remove_index :import_rows, name: "index_import_rows_on_import_id_and_source_row_number"
    remove_check_constraint :import_rows, name: "chk_import_rows_source_row_number_positive"
    remove_column :import_rows, :source_row_number
  end
end
