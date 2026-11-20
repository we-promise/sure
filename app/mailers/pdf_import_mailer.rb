class PdfImportMailer < ApplicationMailer
  def next_steps
    @user = params[:user]
    @pdf_import = params[:pdf_import]
    @import_url = import_url(@pdf_import)
    # The reading that queued this email; one queued before snapshots existed reads the import.
    reading = (params[:reading] || {}).symbolize_keys
    @document_type = reading.fetch(:document_type) { @pdf_import.document_type }
    @summary = reading.fetch(:summary) { @pdf_import.ai_summary }
    @failed_checks = Array(reading.fetch(:failed_checks) { @pdf_import.failed_checks })
    @extractable = @document_type.in?(Ai::PdfReading::STATEMENT_TYPES)

    mail(
      to: @user.email,
      subject: t(".subject", product_name: product_name)
    )
  end
end
