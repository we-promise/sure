# Pushes a Statement Vault upload into the searchable Document Store.
#
# Enqueued from AccountStatement's after_create_commit, so it covers all three
# producers at once: the web Vault, the MCP upload_account_statement tool, and
# PdfImport. Failing here must never fail the upload, which has already
# succeeded and whose bytes are safely stored.
class IndexAccountStatementJob < ApplicationJob
  queue_as :default

  def perform(statement_id)
    statement = AccountStatement.find_by(id: statement_id)
    return unless statement

    statement.index_in_vector_store!
  rescue StandardError => e
    DebugLogEntry.capture(
      category: "documents",
      level: "warn",
      message: "Vector store indexing failed for account statement: #{e.class}: #{e.message}",
      source: "IndexAccountStatementJob",
      family: statement&.family,
      metadata: { account_statement_id: statement_id }
    )
  end
end
