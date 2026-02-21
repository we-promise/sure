class AddBuddyImportColumns < ActiveRecord::Migration[7.2]
  def change
    # Column mapping for parent category header
    add_column :imports, :category_parent_col_label, :string
    # Column mapping for "Paid By" header
    add_column :imports, :paid_by_col_label, :string

    # "Paid By" on import_rows
    add_column :import_rows, :paid_by, :string
  end
end
