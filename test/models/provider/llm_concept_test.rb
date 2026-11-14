require "test_helper"

class Provider::LlmConceptTest < ActiveSupport::TestCase
  test "from_response drops line items that are not objects" do
    extraction = Provider::LlmConcept::ReceiptExtraction.from_response(
      "line_items" => [ [ "Coffee", 4.5 ], "Tea", nil, { "name" => "Bagel", "amount" => "3.25" } ],
      "total" => "3.25"
    )

    assert_equal [ "Bagel" ], extraction.line_items.map(&:name)
  end
end
