require "test_helper"

class AiHealth::Probe::SyntheticPdfTest < ActiveSupport::TestCase
  test "is a valid one-page PDF holding only the synthetic statement" do
    reader = PDF::Reader.new(StringIO.new(AiHealth::Probe::SyntheticPdf.bytes))

    assert_equal 1, reader.page_count
    AiHealth::Probe::SyntheticPdf::LINES.each { assert_includes reader.pages.first.text, _1 }
  end
end
