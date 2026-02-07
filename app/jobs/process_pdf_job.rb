class ProcessPdfJob < ApplicationJob
  queue_as :medium_priority

  def perform(pdf_import)
    return unless pdf_import.is_a?(PdfImport)
    return unless pdf_import.pdf_uploaded?
    return if pdf_import.status == "complete"
    return if pdf_import.ai_processed? && (!pdf_import.bank_statement? || pdf_import.rows_count > 0)

    pdf_import.update!(status: :importing)

    begin
      pdf_import.process_with_ai

      # For bank statements, extract transactions and generate import rows
      if pdf_import.bank_statement?
        Rails.logger.info("ProcessPdfJob: Extracting transactions for bank statement import #{pdf_import.id}")
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

      # Bank statements with rows go to pending for user review/publish
      # Non-bank statements are marked complete (no further action needed)
      final_status = pdf_import.bank_statement? && pdf_import.rows_count > 0 ? :pending : :complete
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
  end

  private

    def sanitize_error_message(error)
      case error
      when RuntimeError, ArgumentError
        I18n.t("imports.pdf_import.processing_failed_with_message",
               message: error.message.truncate(500))
      else
        I18n.t("imports.pdf_import.processing_failed_generic",
               error: error.class.name.demodulize)
      end
    end
end
