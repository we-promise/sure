# What an uploaded PDF is and what it says: its document type, a summary and the
# statement's key figures, from the first batch of its pages.
class Ai::Generations::ReadPdf < Ai::Generation
  include Ai::PdfReading::Pages

  prompt "read_pdf"
  schema_name "document_analysis"

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

  # The first batch is enough to say what a document is. No answer at all (no slice fitted) is
  # unusable, so Auto reads another way rather than classify the file as nothing.
  def merge_values(values)
    values.first || raise(Ai::Error::InvalidOutput, "no batch of the document was answered")
  end
end
