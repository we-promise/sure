# A one-page bank statement with made-up data, built by hand so the PDF probes send no customer
# data and need no PDF library. A model that reads it should name INSTITUTION.
module AiHealth::Probe::SyntheticPdf
  INSTITUTION = "SUREHEALTHCHECKBANK"
  LINES = [
    "Bank Statement",
    "Institution: #{INSTITUTION}",
    "Account holder: Health Check",
    "Statement period: 2026-01-01 to 2026-01-31",
    "Opening balance: USD 100.00",
    "Closing balance: USD 125.00",
    "Transactions: 2",
    "Synthetic data only. No customer data."
  ].freeze

  module_function

  def bytes
    @bytes ||= build.freeze
  end

  # Whether a PDF processor read this statement: a bank statement naming INSTITUTION.
  def valid_result?(result)
    result.is_a?(Provider::LlmConcept::PdfProcessingResult) &&
      result.document_type == "bank_statement" &&
      result.extracted_data.is_a?(Hash) &&
      result.extracted_data["institution_name"] == INSTITUTION
  end

  def build
    text = LINES.map { |line| "(#{line}) Tj T*" }.join("\n")
    content = "BT /F1 14 Tf 24 190 Td 22 TL\n#{text}\nET\n".b
    objects = [
      "<< /Type /Catalog /Pages 2 0 R >>",
      "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
      "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 480 216] /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>",
      "<< /Length #{content.bytesize} >>\nstream\n#{content}endstream",
      "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"
    ]

    pdf = "%PDF-1.4\n".b
    offsets = [ 0 ]
    objects.each_with_index do |object, index|
      offsets << pdf.bytesize
      pdf << "#{index + 1} 0 obj\n#{object}\nendobj\n".b
    end

    xref_offset = pdf.bytesize
    pdf << "xref\n0 #{objects.size + 1}\n".b
    pdf << "0000000000 65535 f \n".b
    offsets.drop(1).each { |offset| pdf << format("%010d 00000 n \n", offset).b }
    pdf << "trailer\n<< /Size #{objects.size + 1} /Root 1 0 R >>\nstartxref\n#{xref_offset}\n%%EOF\n".b
    pdf
  end
  private_class_method :build
end
