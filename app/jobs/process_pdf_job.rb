class ProcessPdfJob < ApplicationJob
  queue_as :medium_priority

  def perform(pdf_import)
    return unless pdf_import.is_a?(PdfImport)
    return unless pdf_import.pdf_uploaded?
    return if pdf_import.ai_processed?

    pdf_import.update!(status: :importing)

    begin
      pdf_import.process_with_ai

      # Find the user who created this import (first admin or any user in the family)
      user = pdf_import.family.users.find_by(role: :admin) || pdf_import.family.users.first

      if user
        pdf_import.send_next_steps_email(user)
      end

      pdf_import.update!(status: :complete)
    rescue => e
      Rails.logger.error("PDF processing failed for import #{pdf_import.id}: #{e.message}")
      pdf_import.update!(status: :failed, error: e.message)
      raise
    end
  end
end
