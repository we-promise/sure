# Main (#5701) linked processed PDFs to their statements in an account_statement_id column. The AI
# plumbing keeps that link in metadata and filters on the document's account
# (FamilyDocument.readable_by), so each link moves there, with its statement's account, and the
# column goes. Processed PDFs left unlinked stay hidden from everyone (readable_by): each family
# with any gets one DebugLogEntry naming them, so support can say why an excerpt is missing.
class MoveFamilyDocumentStatementLinksIntoMetadata < ActiveRecord::Migration[8.1]
  # FamilyDocument::UNKNOWN_STATEMENT, copied so the migration doesn't change with the model.
  UNKNOWN_STATEMENT = <<~SQL.squish.freeze
    family_documents.account_id IS NULL
    AND jsonb_exists(COALESCE(family_documents.metadata, '{}'::jsonb), 'type')
    AND NOT jsonb_exists_any(COALESCE(family_documents.metadata, '{}'::jsonb), array['account_statement_id', 'pdf_import_id'])
  SQL

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

    log_hidden_documents
  end

  def down
    add_reference :family_documents, :account_statement, type: :uuid, index: true,
                  foreign_key: { on_delete: :cascade }
  end

  private
    def log_hidden_documents
      hidden = execute(<<~SQL.squish).cmd_tuples
        INSERT INTO debug_log_entries (family_id, category, level, message, source, metadata, created_at, updated_at)
        SELECT family_id, 'documents', 'warn',
               'Processed PDFs are hidden from document search: which statement each came from is unknown',
               '#{self.class.name}',
               jsonb_build_object('count', COUNT(*), 'family_document_ids', jsonb_agg(id ORDER BY created_at),
                                  'filenames', jsonb_agg(filename ORDER BY created_at)),
               now(), now()
        FROM family_documents
        WHERE #{UNKNOWN_STATEMENT}
        GROUP BY family_id
      SQL
      say "#{hidden} famil#{hidden == 1 ? "y has" : "ies have"} processed PDFs hidden from document search (DebugLogEntry, category documents)" if hidden.positive?
    end
end
