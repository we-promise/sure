# Renders PDF pages to PNGs for the vision endpoint, for PDFs that have no
# text layer (scanned statements and receipts). Shared by PdfProcessor and
# ReceiptExtractor.
module Provider::Openai::Concerns::PdfPageRenderer
  extend ActiveSupport::Concern

  private

    # Render each PDF page to a base64-encoded PNG using pdftoppm
    # (poppler-utils). Distinguishes "renderer binary absent" (raise a coded
    # Provider::Openai::Error with failure_code :render_missing_binary) from
    # "renderer ran but rejected the input" (return [] so the caller can
    # degrade gracefully).
    def render_pdf_pages(pdf_content)
      return [] if pdf_content.blank?

      Dir.mktmpdir do |tmpdir|
        pdf_path = File.join(tmpdir, "input.pdf")
        File.binwrite(pdf_path, pdf_content)

        # Render via pdftoppm (poppler-utils). Kernel#system returns `nil` when
        # the executable cannot be started (binary not installed) and `false`
        # when it runs but exits non-zero (present but rejected the input).
        output_prefix = File.join(tmpdir, "page")
        rendered = system("pdftoppm", "-png", "-r", "150", pdf_path, output_prefix)
        raise pdf_renderer_missing_error if rendered.nil?

        # Read all generated images (empty array when pdftoppm exited non-zero)
        image_files = Dir.glob(File.join(tmpdir, "page-*.png")).sort
        image_files.map do |img_path|
          Base64.strict_encode64(File.binread(img_path))
        end
      end
    rescue Provider::Openai::Error
      raise
    rescue => e
      Rails.logger.error("Failed to convert PDF to images: #{e.message}")
      []
    end

    # Coded error for the "pdftoppm not installed" case so the admin AI status
    # page can show a concrete, actionable failure reason instead of a generic
    # service error.
    def pdf_renderer_missing_error
      Provider::Openai::Error.new(
        "Could not convert PDF to images: pdftoppm (poppler-utils) is not installed",
        failure_code: :render_missing_binary
      )
    end
end
