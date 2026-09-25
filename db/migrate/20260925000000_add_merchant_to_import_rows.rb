class AddMerchantToImportRows < ActiveRecord::Migration[8.1]
  def change
    add_reference :import_rows, :merchant, type: :uuid, foreign_key: { on_delete: :nullify }
  end
end
