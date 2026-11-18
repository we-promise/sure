# Makes a stored statement's search copy (AccountStatement#index_in_vector_store!), on `embed`'s
# lane. The upload has already succeeded, so a failure here is logged for support, never raised.
class IndexAccountStatementJob < ApplicationJob
  queue_as { Ai::Routes.queue_for(:embed) }

  # uploader_id: whose AI switch allowed the upload; checked again here, as it may have been turned
  # off while the job waited. A job queued without one predates the check.
  def perform(statement_id, uploader_id = nil)
    statement = AccountStatement.find_by(id: statement_id)
    return unless statement
    return if uploader_id && !User.find_by(id: uploader_id)&.ai_enabled?
    return unless Ai.available?(:embed, family: statement.family)

    return if statement.index_in_vector_store!
    return if statement.indexed_in_vector_store?
    # Only a configured store refusing the upload is worth recording.
    return unless statement.original_file.attached? && VectorStore.configured?

    DebugLogEntry.capture(
      category: "documents",
      level: "warn",
      message: "Vector store provider refused the account statement upload",
      source: "IndexAccountStatementJob",
      family: statement.family,
      metadata: { account_statement_id: statement_id }
    )
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
