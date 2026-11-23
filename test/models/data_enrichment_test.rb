require "test_helper"

class DataEnrichmentTest < ActiveSupport::TestCase
  test "drop_metadata_flag! removes only that key, and only from the scope" do
    transaction = transactions(:one)
    flagged = DataEnrichment.create!(enrichable: transaction, attribute_name: "category_id", source: "bayes", value: "x", metadata: { "locked_by_bayes" => true, "confidence" => 0.9 })
    other = DataEnrichment.create!(enrichable: transaction, attribute_name: "merchant_id", source: "bayes", value: "y", metadata: { "locked_by_bayes" => true })

    assert_equal 1, DataEnrichment.where(id: flagged.id).drop_metadata_flag!("locked_by_bayes")

    assert_equal({ "confidence" => 0.9 }, flagged.reload.metadata)
    assert_equal({ "locked_by_bayes" => true }, other.reload.metadata)
  end
end
