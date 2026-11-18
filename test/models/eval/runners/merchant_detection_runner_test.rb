require "test_helper"

class Eval::Runners::MerchantDetectionRunnerTest < ActiveSupport::TestCase
  include ProviderTestHelper

  test "a sample with no answer counts as null-expected only when it expects neither a name nor a website" do
    dataset = Eval::Dataset.create!(name: "test_merchant_missing_#{SecureRandom.hex(4)}", eval_type: "merchant_detection", version: "1.0")
    url_only = dataset.samples.create!(
      input_data: { "id" => "txn_1", "amount" => 12, "classification" => "expense", "description" => "SQ *BLUE BOTTLE" },
      expected_output: { "business_name" => nil, "business_url" => "bluebottlecoffee.com" }, context_data: { "merchants" => [] }, difficulty: "edge_case"
    )
    eval_run = Eval::Run.create!(dataset:, provider: "openai", model: "gpt-4.1", name: "test_run",
                                 provider_config: { "access_token" => "test-token" }, status: "pending")
    Eval::GenerationClient.any_instance.stubs(:auto_detect_merchants).returns(provider_success_response([]))

    Eval::Runners::MerchantDetectionRunner.new(eval_run).run

    result = eval_run.results.find_by(eval_sample_id: url_only.id)
    assert_equal "no answer for this sample", result.actual_output["error"]
    assert_not result.null_expected
  end
end
