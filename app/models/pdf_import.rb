class PdfImport < Import
  has_one_attached :pdf_file

  validates :document_type, inclusion: { in: DOCUMENT_TYPES }, allow_nil: true

  def pdf_uploaded?
    pdf_file.attached?
  end

  def ai_processed?
    ai_summary.present?
  end

  def process_with_ai_later
    ProcessPdfJob.perform_later(self)
  end

  def process_with_ai
    provider = Provider::Registry.get_provider(:openai)
    raise "AI provider not configured" unless provider
    raise "AI provider does not support PDF processing" unless provider.supports_pdf_processing?

    response = provider.process_pdf(
      pdf_content: pdf_file_content,
      family: family
    )

    unless response.success?
      error_message = response.error&.message || "Unknown PDF processing error"
      raise error_message
    end

    result = response.data
    update!(
      ai_summary: result.summary,
      document_type: result.document_type
    )

    result
  end

  def send_next_steps_email(user)
    PdfImportMailer.with(
      user: user,
      pdf_import: self
    ).next_steps.deliver_later
  end

  def uploaded?
    pdf_uploaded?
  end

  def configured?
    ai_processed?
  end

  def cleaned?
    ai_processed?
  end

  def publishable?
    false
  end

  def column_keys
    []
  end

  def required_column_keys
    []
  end

  def requires_csv_workflow?
    false
  end

  def pdf_file_content
    return nil unless pdf_file.attached?

    pdf_file.download
  end
end
