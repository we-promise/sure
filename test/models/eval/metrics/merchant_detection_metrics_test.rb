require "test_helper"

class Eval::Metrics::MerchantDetectionMetricsTest < ActiveSupport::TestCase
  test "counts unanswered samples as errored, apart from wrong answers" do
    dataset = Eval::Dataset.create!(name: "merchants_#{SecureRandom.hex(4)}", eval_type: "merchant_detection", version: "1.0")
    run = Eval::Run.create!(dataset:, provider: "jev", model: "jev-latest", name: "errors", status: "running")
    [ nil, nil, "Timeout" ].each_with_index do |error, index|
      sample = dataset.samples.create!(input_data: { "description" => "txn #{index}" },
                                       expected_output: { "business_name" => "Netflix" }, difficulty: "easy")
      run.results.create!(sample:, actual_output: { "business_name" => (error ? nil : "Hulu") }, correct: false,
                          metadata: error ? { "error" => error } : {})
    end

    metrics = Eval::Metrics::MerchantDetectionMetrics.new(run).calculate

    assert_equal [ 3, 1, 33.33 ], metrics.values_at(:samples_processed, :samples_errored, :error_rate)
  end
end
