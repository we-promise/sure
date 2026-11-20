# Reads an uploaded PDF: what it is (ReadPdf), its search copy (embed), and for a
# statement its rows (ExtractBankStatement), through Ai::PdfReading. On extract_pdf's lane.
class ProcessPdfJob < ApplicationJob
  queue_as { Ai::Routes.queue_for(:extract_pdf) }

  # Marked failed with its reason before it's raised, and a failed import isn't processed again,
  # so a retry would do nothing: the user reads it again or uploads again.
  discard_on(Ai::Error::Base, Pdf::PageImages::Error) do |job, err|
    Rails.logger.error("[ProcessPdfJob] Discarded permanently (job_id=#{job.job_id}, error_class=#{err.class.name})")
  end

  # reread: "Read again as…" claimed the import with reread_token; the previous
  # reading is cleared here, under the lock that verifies that claim.
  def perform(pdf_import, reread: false, reread_token: nil)
    return unless pdf_import.is_a?(PdfImport)
    if reread
      return if reread_token.blank?
      return unless pdf_import.clear_reading!(reread_token: reread_token)
    end
    return reset_processing_claim(pdf_import) unless pdf_import.pdf_uploaded?
    return if pdf_import.status.in?(%w[complete failed])
    return reset_processing_claim(pdf_import) if pdf_import.ai_processed? && (!pdf_import.statement_with_transactions? || pdf_import.rows_count > 0)

    pdf_import.update!(status: :importing, reread_token: nil)

    Ai::CallContext.job("pdf_import:#{pdf_import.id}") { process(pdf_import) }
  rescue Ai::Error::Base, Pdf::PageImages::Error => e
    # discard_on below must not retire a job whose failed status is unrecorded. A failed write
    # raises a different error, so the job is retried instead of discarded.
    record_failed_status(pdf_import, e)
    raise
  end

  private
    def process(pdf_import)
      process_result = pdf_import.process_with_ai
      document_type = resolve_document_type(pdf_import, process_result)
      upload_to_vector_store(pdf_import, document_type: document_type)

      # For statements with transactions (bank/credit card), extract and generate import rows
      if statement_with_transactions?(document_type)
        Rails.logger.info("ProcessPdfJob: Extracting transactions for #{document_type} import #{pdf_import.id}")
        pdf_import.extract_transactions
        Rails.logger.info("ProcessPdfJob: Extracted #{pdf_import.extracted_transactions.size} transactions")

        pdf_import.generate_rows_from_extracted_data
        pdf_import.sync_mappings
        Rails.logger.info("ProcessPdfJob: Generated #{pdf_import.rows_count} import rows")
      end

      # Find the user who created this import (first admin or any user in the family)
      user = pdf_import.family.users.find_by(role: :admin) || pdf_import.family.users.first

      if user
        pdf_import.send_next_steps_email(user)
      end

      # Statements with extracted rows go to pending for user review/publish
      # Other document types are marked complete (no further action needed)
      final_status = statement_with_transactions?(document_type) && pdf_import.rows_count > 0 ? :pending : :complete
      pdf_import.update!(status: final_status)
    rescue StandardError => e
      sanitized_error = sanitize_error_message(e)
      Rails.logger.error("PDF processing failed for import #{pdf_import.id}: #{e.class.name} - #{sanitized_error}")
      begin
        pdf_import.update!(status: :failed, error: sanitized_error)
      rescue StandardError => update_error
        Rails.logger.error("Failed to update import status: #{update_error.message}")
      end
      raise
    end

    # Provider errors about the account, not the document: their message is the useful part (a
    # spent balance, a wrong key) and quotes nothing from the statement.
    ACCOUNT_ERRORS = [ Ai::Error::NoCredit, Ai::Error::Unauthorized, Ai::Error::RateLimited, Ai::Error::ModelMissing ].freeze

    # What the import page shows: why no model could read it (the router's reason or the way's),
    # the provider's message for an account error, a rendering failure's concrete reason (#3275),
    # or the error class. Any other provider message can quote the statement back (an account
    # number), which the key scrubber doesn't catch, so it's never shown or logged.
    def sanitize_error_message(error)
      case error
      when Ai::Error::Unavailable then PdfImport.unavailable_message(error.reason)
      when *ACCOUNT_ERRORS
        I18n.t("imports.pdf_import.processing_failed_with_message", message: error.message.truncate(500))
      when Ai::Error::Base
        I18n.t("imports.pdf_import.processing_failed_generic", error: error.class.name.demodulize)
      when Pdf::PageImages::Error, RuntimeError, ArgumentError
        I18n.t("imports.pdf_import.processing_failed_with_message",
               message: error.message.truncate(500))
      else
        I18n.t("imports.pdf_import.processing_failed_generic",
               error: error.class.name.demodulize)
      end
    end

    # One search copy per statement, shared with IndexAccountStatementJob, which runs on another
    # queue in no fixed order: both check for the copy under the statement's row lock. Unlike a
    # vault upload, no user's AI switch is checked: starting a PDF import is asking for AI, and the
    # search copy is part of it.
    def upload_to_vector_store(pdf_import, document_type:)
      return unless Ai.available?(:embed, family: pdf_import.family)

      statement = pdf_import.account_statement

      return upload_document(pdf_import, document_type, nil) if statement.nil?

      statement.with_lock { upload_document(pdf_import, document_type, statement) }
    end

    def upload_document(pdf_import, document_type, statement)
      statement_id = statement&.id

      documents = pdf_import.family.family_documents
      existing = (documents.find_by("metadata->>'account_statement_id' = ?", statement_id) if statement_id.present?) ||
                 documents.find_by("metadata->>'pdf_import_id' = ?", pdf_import.id)   # read again
      return existing.poll_index_later if existing

      family_document = pdf_import.family.upload_document(
        file_content: pdf_import.pdf_file_content,
        filename: pdf_import.pdf_filename,
        metadata: {
          "type" => document_type,
          "pdf_import_id" => pdf_import.id,
          "account_statement_id" => statement_id,
          "account_id" => statement&.account_id || pdf_import.account_id
        }.compact
      )

      return if family_document

      Rails.logger.warn("ProcessPdfJob: Vector store upload failed for import #{pdf_import.id}")
    end

    def resolve_document_type(pdf_import, process_result)
      return process_result.document_type if process_result.respond_to?(:document_type) && process_result.document_type.present?

      pdf_import.reload.document_type
    end

    def statement_with_transactions?(document_type)
      document_type.in?(Ai::PdfReading::STATEMENT_TYPES)
    end

    # process itself records its failure; this covers an error raised before it
    # starts. A job whose claim was already released must not fail a newer one.
    def record_failed_status(pdf_import, error)
      return true unless pdf_import.is_a?(PdfImport)

      pdf_import.with_lock do
        pdf_import.update!(status: :failed, error: sanitize_error_message(error)) if pdf_import.importing?
      end
      true
    rescue StandardError => update_error
      Rails.logger.error("Failed to record ProcessPdfJob failure: #{update_error.message}")
      raise update_error   # not an Ai::Error, so discard_on can't retire this job
    end

    def reset_processing_claim(pdf_import)
      pdf_import.with_lock do
        pdf_import.update!(status: :pending, reread_token: nil) if pdf_import.importing? && pdf_import.updated_at <= 30.minutes.ago
      end
    end
end
