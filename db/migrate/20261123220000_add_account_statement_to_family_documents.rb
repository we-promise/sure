# A processed statement PDF is searchable by whoever may see its statement
# (FamilyDocument.searchable_by), so its document records which one it is.
class AddAccountStatementToFamilyDocuments < ActiveRecord::Migration[8.1]
  def change
    add_reference :family_documents, :account_statement, type: :uuid, foreign_key: { on_delete: :cascade }, index: true
  end
end
