require "test_helper"

class Ai::Generations::DetectMerchantsTest < ActiveSupport::TestCase
  def generation(merchants: [ { id: "m1", name: "Shooters" } ])
    Ai::Generations::DetectMerchants.new(transactions: [ { id: "t1" }, { id: "t2" } ], merchants:, family: nil)
  end

  test "a name matching one of the family's merchants takes its spelling" do
    value = generation.coerce({ "merchants" => [ { "transaction_id" => "t1", "business_name" => "SHOOTERS", "business_url" => "null" } ] })

    assert_equal({ transaction_id: "t1", business_name: "Shooters", business_url: nil }, value[:merchants].first)
  end
end
