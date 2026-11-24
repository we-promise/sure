# Main (#5701) linked processed PDFs to their statements in an account_statement_id column. The AI
# plumbing keeps that link in metadata and filters on the document's account
# (FamilyDocument.readable_by), so each link moves there, with its statement's account, and the
# column goes. Processed PDFs left unlinked stay hidden from everyone (readable_by).
class MoveFamilyDocumentStatementLinksIntoMetadata < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL.squish
      UPDATE family_documents
      SET metadata = COALESCE(family_documents.metadata, '{}'::jsonb) || jsonb_build_object('account_statement_id', statements.id::text),
          account_id = statements.account_id
      FROM account_statements AS statements
      WHERE statements.id = family_documents.account_statement_id
        AND family_documents.metadata->>'account_statement_id' IS NULL
    SQL

    remove_reference :family_documents, :account_statement, type: :uuid, index: true,
                     foreign_key: { on_delete: :cascade }
  end

  def down
    add_reference :family_documents, :account_statement, type: :uuid, index: true,
                  foreign_key: { on_delete: :cascade }
  end
end
