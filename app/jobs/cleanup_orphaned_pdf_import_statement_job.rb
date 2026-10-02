class CleanupOrphanedPdfImportStatementJob < ApplicationJob
  queue_as :low_priority

  retry_on StandardError, wait: :polynomially_longer, attempts: 5 do |job, error|
    Rails.logger.error(
      "Could not clean up source statement #{job.arguments.first} after retries: #{error.class}: #{error.message}"
    )
  end

  def perform(statement_id)
    statement = AccountStatement.find_by(id: statement_id)
    return unless statement

    statement.family.with_lock do
      # Re-fetch after taking the same family lock used by PDF upload creation.
      # If cleanup wins, a waiting upload will perform a fresh duplicate lookup
      # and create a new source statement from its prepared file.
      statement = AccountStatement.find_by(id: statement_id)
      return unless statement

      statement.with_lock do
        return unless statement.pdf_import_owned?
        return if statement.account_id.present? || statement.pdf_imports.exists?

        statement.destroy!
      end
    end
  end
end
