require "test_helper"

class Ai::PdfReading::UnitTest < ActiveSupport::TestCase
  test "a page image costs a fixed estimate per page, a text chunk its tokens" do
    assert_equal Ai::PdfReading::Unit::PAGE_IMAGE_TOKENS, Ai::PdfReading::Unit.page(3).cost
    assert_equal 2 * Ai::PdfReading::Unit::PAGE_IMAGE_TOKENS, Ai::PdfReading::Unit.pdf(2).cost
    assert_equal Assistant::TokenEstimator.estimate("some text"), Ai::PdfReading::Unit.text("some text", page: 1).cost
  end

  test "its constants stay in its own namespace" do
    assert_not Object.const_defined?(:PAGE_IMAGE_TOKENS, false)
  end
end
