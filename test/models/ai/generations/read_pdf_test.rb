require "test_helper"

# What a PDF is: today's analysis instructions, the first batch only, and a
# document type outside Import::DOCUMENT_TYPES coerced to nil.
class Ai::Generations::ReadPdfTest < ActiveSupport::TestCase
  setup do
    use_ai_routes(extract_pdf: %w[gpu/qwen3-8b])
    @family = families(:dylan_family)
  end

  test "sends today's instructions with the text layer, and reads the first batch only" do
    use_ai_model_settings(batch_size: 1)   # two batches, so batches: 1 has one to leave
    requests = stub_ai(:extract_pdf, returns: { document_type: "bank_statement", summary: "A statement", extracted_data: nil })
    units = [ Ai::PdfReading::Unit.text("page one", page: 1), Ai::PdfReading::Unit.text("page two", page: 2) ]

    result = generation(units).call(batches: 1)

    assert result.success?
    assert_equal [ units.last ], result.remaining
    assert_equal "bank_statement", result.value[:document_type]
    assert_match "You are a financial document analysis assistant", requests.sole.instructions
    assert_match "--- Page 1 ---\npage one", requests.sole.input
  end

  test "page images are rendered and sent for the batch's own pages only, even when they aren't contiguous" do
    Pdf::PageImages.expects(:render).with("%PDF", pages: [ 2, 4 ]).returns(%w[png2 png4])

    attachments = generation([ Ai::PdfReading::Unit.page(2), Ai::PdfReading::Unit.page(4) ]).attachments

    assert_equal %w[page-2.png page-4.png], attachments.map(&:filename)
    assert_equal %w[png2 png4], attachments.map(&:data)
  end

  test "a statement classified in a later piece wins over a cover page" do
    stub_ai(:extract_pdf) do |request|
      raise Ai::Error::ContextTooLong, "too long" if request.input.include?("PAGE ONE") && request.input.include?("PAGE TWO")

      if request.input.include?("PAGE ONE")
        { document_type: "other", summary: "cover", extracted_data: nil }
      else
        { document_type: "bank_statement", summary: "statement", extracted_data: nil }
      end
    end
    units = [ Ai::PdfReading::Unit.text("PAGE ONE", page: 1), Ai::PdfReading::Unit.text("PAGE TWO", page: 2) ]

    result = generation(units).call(batches: 1)

    assert result.success?
    assert_equal "bank_statement", result.value[:document_type]
  end

  test "no batch answered is unusable, not a document of no type" do
    generation = Ai::Generations::ReadPdf.new(units: [], content: "", family: nil)

    assert_raises(Ai::Error::InvalidOutput) { generation.merge_values([]) }
  end

  private
    def generation(units) = Ai::Generations::ReadPdf.new(units:, content: "%PDF", family: @family)
end
