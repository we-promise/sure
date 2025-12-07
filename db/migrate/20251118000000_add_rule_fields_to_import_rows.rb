class AddRuleFieldsToImportRows < ActiveRecord::Migration[7.2]
  def change
    add_column :import_rows, :resource_type, :string
    add_column :import_rows, :active, :boolean
    add_column :import_rows, :effective_date, :string
    add_column :import_rows, :conditions, :text
    add_column :import_rows, :actions, :text
  end
end
