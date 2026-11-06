# What an uploaded PDF is and what it says (section 8.1): its document type, a summary and the
# statement's key figures, from the first batch of its pages. Replaces
# Provider::{Openai,Anthropic}::PdfProcessor.
class Ai::Generations::ReadPdf < Ai::Generation
  include Ai::PdfReading::Pages

  prompt "read_pdf"
  schema_name "document_analysis"

  NULLABLE_STRING = { type: %w[string null] }.freeze
  NULLABLE_NUMBER = { type: %w[number null] }.freeze

  schema({
    type: "object",
    properties: {
      document_type: { type: %w[string null], enum: Import::DOCUMENT_TYPES + [ nil ] },
      summary: { type: %w[string null] },
      extracted_data: {
        type: %w[object null],
        properties: {
          institution_name: NULLABLE_STRING, statement_period_start: NULLABLE_STRING, statement_period_end: NULLABLE_STRING,
          transaction_count: { type: %w[integer null] }, opening_balance: NULLABLE_NUMBER, closing_balance: NULLABLE_NUMBER,
          currency: NULLABLE_STRING, account_holder: NULLABLE_STRING
        },
        required: %w[institution_name statement_period_start statement_period_end transaction_count opening_balance
                     closing_balance currency account_holder],
        additionalProperties: false
      }
    },
    required: %w[document_type summary extracted_data],
    additionalProperties: false
  }.freeze)

  # The first batch is enough to say what a document is, as today's text path read the first
  # 100,000 characters and its image path the first five pages.
  def merge_values(values) = values.first || {}
end
