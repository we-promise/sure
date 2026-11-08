# The AI steps of a PDF import: reading the document, then extracting a statement's
# transactions. PdfImport keeps the record, its state and its rows.
class PdfImport::AiProcessor
  def initialize(pdf_import)
    @pdf_import = pdf_import
  end

  def process
    require_ai_for_extraction!
    # The first provider in extract_pdf's route.
    provider = Provider::Registry.preferred_llm_provider
    raise Provider::Error, I18n.t("imports.pdf_import.errors.provider_no_pdf_support") unless provider.supports_pdf_processing?

    response = provider.process_pdf(
      pdf_content: pdf_import.pdf_file_content,
      family: pdf_import.family
    )

    unless response.success?
      error_message = response.error&.message || "Unknown PDF processing error"
      raise Provider::Error, error_message
    end

    result = response.data
    pdf_import.update!(
      ai_summary: result.summary,
      document_type: result.document_type
    )

    result
  end

  def extract_transactions
    return unless pdf_import.statement_with_transactions?

    require_ai_for_extraction!
    provider = Provider::Registry.preferred_llm_provider

    response = provider.extract_bank_statement(
      pdf_content: pdf_import.pdf_file_content,
      family: pdf_import.family
    )

    unless response.success?
      error_message = response.error&.message || "Unknown extraction error"
      raise Provider::Error, error_message
    end

    # BankStatementExtractor returns symbol keys, but every reader here (and in
    # generate_rows_from_extracted_data) digs with strings. jsonb keeps the hash
    # exactly as assigned until the record is reloaded, so without this the
    # in-memory read comes back empty and the import produces no rows at all.
    data = response.data.deep_stringify_keys
    pdf_import.update!(extracted_data: data)
    data
  end

  private
    attr_reader :pdf_import

    # Asks the router whether a statement can be read, before the job calls a model. The
    # message is the router's reason, worded for the family member who uploaded it.
    def require_ai_for_extraction!
      availability = Ai.availability(:extract_pdf, family: pdf_import.family)
      raise Provider::Error, availability.message_for(nil) unless availability.available?
    end
end
