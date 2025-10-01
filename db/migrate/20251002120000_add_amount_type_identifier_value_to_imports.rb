class AddAmountTypeIdentifierValueToImports < ActiveRecord::Migration[7.2]
  def change
    add_column :imports, :amount_type_identifier_value, :string
  end
end