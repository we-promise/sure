class AddExternalIdToImportColumns < ActiveRecord::Migration[7.2]
  def change
    # Lets a CSV import map a column (e.g. a bank-provided transaction UUID) to
    # the entry external_id used by the sync/dedup system.
    add_column :imports, :external_id_col_label, :string
    add_column :import_rows, :external_id, :string
  end
end
