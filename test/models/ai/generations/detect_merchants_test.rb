require "test_helper"

class Ai::Generations::DetectMerchantsTest < ActiveSupport::TestCase
  def generation(merchants: [ { id: "m1", name: "Shooters" } ])
    Ai::Generations::DetectMerchants.new(transactions: [ { id: "t1" }, { id: "t2" } ], merchants:, family: nil)
  end

  test "a name matching one of the family's merchants takes its spelling" do
    value = generation.coerce({ "merchants" => [ { "transaction_id" => "t1", "business_name" => "SHOOTERS", "business_url" => "null" } ] })

    assert_equal({ transaction_id: "t1", business_name: "Shooters", business_url: nil }, value[:merchants].first)
  end

  test "auto mode counts an answer without both a name and a website as failed" do
    answer = { "merchants" => [ { "transaction_id" => "t1", "business_name" => "Amazon", "business_url" => "amazon.com" },
                                { "transaction_id" => "t2", "business_name" => "Local", "business_url" => nil } ] }

    assert_equal 0.5, generation.failed_ratio(answer)
    assert_equal 1.0, generation.failed_ratio({ "merchants" => [] })
  end
end
