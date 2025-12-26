class AddAmountTypeIdentifierValueToImports < ActiveRecord::Migration[7.2]
  def change
    unless column_exists?(:imports, :amount_type_identifier_value)
      add_column :imports, :amount_type_identifier_value, :string
    end
  end
end
