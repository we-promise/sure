require "test_helper"

class Ai::Generations::EnhanceMerchantsTest < ActiveSupport::TestCase
  test "today's other field names are accepted, and ids outside the batch dropped" do
    generation = Ai::Generations::EnhanceMerchants.new(merchants: [ { id: "m1", name: "Walmart" } ], family: nil)

    value = generation.coerce({ "results" => [ { "id" => "m1", "website" => "walmart.com" }, { "id" => "other", "url" => "x.com" } ] })

    assert_equal [ { merchant_id: "m1", business_url: "walmart.com" } ], value[:merchants]
  end
end
