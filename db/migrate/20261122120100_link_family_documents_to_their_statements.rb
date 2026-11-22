# Documents ProcessPdfJob uploaded before they recorded their statement carry
# only the document type it classified. Each is linked to the one statement of
# its family with the same filename and size; the rest stay unlinked, and
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
        JOIN active_storage_attachments AS attachments
          ON attachments.record_type = 'AccountStatement'
         AND attachments.record_id = statements.id
         AND attachments.name = 'original_file'
        JOIN active_storage_blobs AS blobs
          ON blobs.id = attachments.blob_id
         AND blobs.byte_size = documents.file_size
        WHERE documents.account_statement_id IS NULL
          AND documents.metadata ? 'type'
        GROUP BY documents.id
        HAVING COUNT(DISTINCT statements.id) = 1
      ) AS matches
      WHERE family_documents.id = matches.document_id
    SQL
  end

  def down
  end
end
