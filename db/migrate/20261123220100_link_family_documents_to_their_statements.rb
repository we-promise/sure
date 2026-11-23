# Documents ProcessPdfJob uploaded before they recorded their statement carry
# only the document type it classified. Each is linked to the one statement of
# its family with the same filename and size that a PdfImport had already
# processed when the document was uploaded, so a PDF imported before statements
# existed is never taken for a later statement. The rest stay unlinked, and
# nobody finds them in a search (FamilyDocument.searchable_by).
class LinkFamilyDocumentsToTheirStatements < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL.squish
      UPDATE family_documents
      SET account_statement_id = matches.statement_id
      FROM (
        SELECT documents.id AS document_id, MIN(statements.id::text)::uuid AS statement_id
        FROM family_documents AS documents
        JOIN account_statements AS statements
          ON statements.family_id = documents.family_id
         AND statements.filename = documents.filename
         AND statements.byte_size = documents.file_size
        WHERE documents.account_statement_id IS NULL
          AND documents.metadata ? 'type'
          AND EXISTS (
            SELECT 1 FROM imports
            WHERE imports.type = 'PdfImport'
              AND imports.account_statement_id = statements.id
              AND imports.created_at <= documents.created_at
          )
        GROUP BY documents.id
        HAVING COUNT(DISTINCT statements.id) = 1
      ) AS matches
      WHERE family_documents.id = matches.document_id
    SQL
  end

  def down
  end
end
