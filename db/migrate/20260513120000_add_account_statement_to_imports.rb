class AddAccountStatementToImports < ActiveRecord::Migration[7.2]
  def change
    add_reference :imports, :account_statement, type: :uuid, foreign_key: { on_delete: :nullify }, index: true
  end
end
