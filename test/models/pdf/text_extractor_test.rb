require "test_helper"

class Pdf::TextExtractorTest < ActiveSupport::TestCase
  setup do
    @content = file_fixture("account_statements/trade_republic_it_2026_04.pdf").binread
  end

  test "returns the text of each page" do
    pages = Pdf::TextExtractor.pages(@content)

    assert pages.any?
    assert_match(/Trade Republic/i, pages.join("\n"))
  end

  test "stops after max_pages" do
    PDF::Reader.any_instance.stubs(:pages).returns(%w[one two three].map { |text| stub(text: text) })

    assert_equal %w[one two], Pdf::TextExtractor.pages(@content, max_pages: 2)
  end

  test "raises for content that is not a PDF" do
    assert_raises(PDF::Reader::MalformedPDFError) { Pdf::TextExtractor.pages("not a pdf") }
  end
end
