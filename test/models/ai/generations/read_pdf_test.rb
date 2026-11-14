require "test_helper"

# What a PDF is: today's analysis instructions, the first batch only, and a
# document type outside Import::DOCUMENT_TYPES coerced to nil.
class Ai::Generations::ReadPdfTest < ActiveSupport::TestCase
  setup do
    use_ai_routes(extract_pdf: %w[gpu/qwen3-8b])
    @family = families(:dylan_family)
  end

  test "sends today's instructions with the text layer, and reads the first batch only" do
    requests = stub_ai(:extract_pdf, returns: { document_type: "bank_statement", summary: "A statement", extracted_data: nil })
    units = [ Ai::PdfReading::Unit.text("page one", page: 1), Ai::PdfReading::Unit.text("page two", page: 2) ]

    result = with_ai_model_settings { generation(units).call(batches: 1) }

    assert result.success?
    assert_equal "bank_statement", result.value[:document_type]
    assert_match "You are a financial document analysis assistant", requests.sole.instructions
    assert_match "--- Page 1 ---\npage one", requests.sole.input
  end

  test "a document type outside the list is nil, and a missing section is nil" do
    stub_ai(:extract_pdf, returns: { document_type: "receipt", summary: "x", extracted_data: nil })

    result = generation([ Ai::PdfReading::Unit.text("text", page: 1) ]).call(batches: 1)

    assert_nil result.value[:document_type]
    assert_nil result.value[:extracted_data]
  end

  test "pages as images need vision, so a text model isn't sent them" do
    requests = stub_ai(:extract_pdf, returns: {})

    result = generation([ Ai::PdfReading::Unit.page(1) ]).call(batches: 1)

    assert_equal :capability_missing, result.availability.reason
    assert_empty requests
  end

  private
    def generation(units) = Ai::Generations::ReadPdf.new(units:, content: "%PDF", family: @family)
end
