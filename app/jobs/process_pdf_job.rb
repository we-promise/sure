# Reads an uploaded PDF: what it is (ReadPdf), its search copy (embed), and for a
# statement its rows (ExtractBankStatement), through Ai::PdfReading. On extract_pdf's lane.
class ProcessPdfJob < ApplicationJob
  queue_as { Ai::Routes.queue_for(:extract_pdf) }

  # reread: "Read again as…" claimed the import with reread_token; the previous
  # reading is cleared here, under the lock that verifies that claim. The token stays until a
  # terminal status, so a retry after cleanup can resume instead of being rejected as stale.
  def perform(pdf_import, reread: false, reread_token: nil)
    return unless pdf_import.is_a?(PdfImport)
    if reread
      return if reread_token.blank?
      return unless pdf_import.clear_reading!(reread_token: reread_token)
    end
    return reset_processing_claim(pdf_import) unless pdf_import.pdf_uploaded?
    return if pdf_import.status.in?(%w[complete failed])
    return reset_processing_claim(pdf_import) if pdf_import.ai_processed? && (!pdf_import.statement_with_transactions? || pdf_import.rows_count > 0)

    token = reread ? reread_token : nil
    # Keep the family this job started with: with_lock reloads the import and can reset its
    # association cache, but the vector copy belongs to the family that queued this attempt.
    family = pdf_import.family
    pdf_import.update!(status: :importing, reread_token: token)

    Ai::CallContext.job("pdf_import:#{pdf_import.id}") { process(pdf_import, family:, reread_token: token) }
  rescue Ai::Error::Base, Pdf::PageImages::Error => e
    # The import is marked failed with its reason, and a failed import isn't processed again, so
    # the job ends here: the user reads it again or uploads again. It isn't re-raised, since
    # Active Job would log the provider's message. A failed write raises a different error, so the
    # job is retried.
    record_failed_status(pdf_import, e, reread_token: token)
    Rails.logger.error("[ProcessPdfJob] failed (job_id=#{job_id}, error_class=#{e.class.name})")
  end

  private
    def process(pdf_import, family:, reread_token: nil)
      process_result = pdf_import.process_with_ai(reread_token:)
      return unless process_result
      return unless owns_claim?(pdf_import, reread_token)

      document_type = resolve_document_type(pdf_import, process_result)
      upload_to_vector_store(pdf_import, family:, document_type:)

      # For statements with transactions (bank/credit card), extract and generate import rows
      if statement_with_transactions?(document_type)
        Rails.logger.info("ProcessPdfJob: Extracting transactions for #{document_type} import #{pdf_import.id}")
        return unless pdf_import.extract_transactions(reread_token:)
        Rails.logger.info("ProcessPdfJob: Extracted #{pdf_import.extracted_transactions.size} transactions")

        return unless pdf_import.with_claim(reread_token) do
          pdf_import.generate_rows_from_extracted_data
          pdf_import.sync_mappings
          true
        end
        Rails.logger.info("ProcessPdfJob: Generated #{pdf_import.rows_count} import rows")
      end

      return unless owns_claim?(pdf_import, reread_token)

      # Find the user who created this import (first admin or any user in the family)
      user = family.users.find_by(role: :admin) || family.users.first
      pdf_import.send_next_steps_email(user) if user

      # Statements with extracted rows go to pending for user review/publish
      # Other document types are marked complete (no further action needed)
      final_status = statement_with_transactions?(document_type) && pdf_import.rows_count > 0 ? :pending : :complete
      pdf_import.with_claim(reread_token) { pdf_import.update!(status: final_status, reread_token: nil) }
    rescue Ai::Error::Base, Pdf::PageImages::Error => e
      # The outer rescue records these through the same claim fence.
      raise
    rescue StandardError => e
      sanitized_error = sanitize_error_message(e)
      Rails.logger.error("PDF processing failed for import #{pdf_import.id}: #{e.class.name} - #{sanitized_error}")
      begin
        record_failed_status(pdf_import, e, reread_token: reread_token, message: sanitized_error)
      rescue StandardError => update_error
        Rails.logger.error("Failed to update import status: #{update_error.message}")
      end
      raise
    end

    # Account errors are distinguishable without showing the provider's message: that text can
    # echo request details, so only fixed, class-specific text reaches the import page.
    ACCOUNT_ERRORS = {
      Ai::Error::NoCredit => "no_credit",
      Ai::Error::Unauthorized => "unauthorized",
      Ai::Error::RateLimited => "rate_limited",
      Ai::Error::ModelMissing => "model_missing"
    }.freeze

    # What the import page shows: why no model could read it (the router's reason or the way's),
    # fixed text for an account error, a rendering failure's concrete reason (#3275),
    # or the error class. Any other provider message can quote the statement back (an account
    # number), which the key scrubber doesn't catch, so it's never shown or logged.
    def sanitize_error_message(error)
      case error
      when Ai::Error::Unavailable then PdfImport.unavailable_message(error.reason)
      when *ACCOUNT_ERRORS.keys
        I18n.t("imports.pdf_import.account_errors.#{ACCOUNT_ERRORS.fetch(error.class)}")
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
    # search copy is part of it. Who finds a copy follows its statement (FamilyDocument.readable_by),
    # so an import from before statements existed, which has none, gets no copy.
    def upload_to_vector_store(pdf_import, family:, document_type:)
      statement = pdf_import.account_statement
      return if statement.nil? || !Ai.available?(:embed, family:)

      statement.with_lock { upload_document(pdf_import, family, document_type, statement) }
    end

    def upload_document(pdf_import, family, document_type, statement)
      documents = family.family_documents.search_copies
      existing = documents.find_by("metadata->>'account_statement_id' = ?", statement.id) ||
                 documents.find_by("metadata->>'pdf_import_id' = ?", pdf_import.id)   # read again
      return existing.poll_index_later if existing

      family_document = family.upload_document(
        file_content: pdf_import.pdf_file_content,
        filename: pdf_import.pdf_filename,
        metadata: {
          "type" => document_type,
          "pdf_import_id" => pdf_import.id,
          "account_statement_id" => statement.id,
          "account_id" => statement.account_id
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

    # A stale job must leave a replacement claim and its data untouched, wherever it is when
    # the claim changes. Checked under the same row lock used to write each terminal status.
    def owns_claim?(pdf_import, reread_token)
      pdf_import.with_lock do
        next false if reread_token.blank? && pdf_import.reread_token.present?
        next false if reread_token.present? && !(pdf_import.importing? && pdf_import.reread_token == reread_token)

        true
      end
    end

    # process itself records its failure; this covers an error raised before it
    # starts. A job whose claim was already released must not fail a newer one.
    def record_failed_status(pdf_import, error, reread_token: nil, message: nil)
      return true unless pdf_import.is_a?(PdfImport)

      pdf_import.with_claim(reread_token) do
        pdf_import.update!(status: :failed, error: message || sanitize_error_message(error), reread_token: nil)
      end
      true
    rescue StandardError => update_error
      Rails.logger.error("Failed to record ProcessPdfJob failure: #{update_error.message}")
      raise update_error   # not an Ai::Error, so discard_on can't retire this job
    end

    # A redelivery of a job whose worker stopped: the same recovery as the reaper's, so a
    # classified import can be read again and an unclassified one goes back to pending.
    def reset_processing_claim(pdf_import)
      needs_sync = pdf_import.with_lock do
        pdf_import.importing? && pdf_import.updated_at <= 30.minutes.ago && pdf_import.recover_lost_claim!
      end
      pdf_import.family.sync_later if needs_sync
    end
end
