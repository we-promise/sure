require "test_helper"

class Eval::Metrics::CalibrationTest < ActiveSupport::TestCase
  setup do
    @dataset = Eval::Dataset.create!(
      name: "test_calib_#{SecureRandom.hex(4)}",
      eval_type: "categorization",
      version: "1.0"
    )
    @run = Eval::Run.create!(
      dataset: @dataset, provider: "jev", model: "jev-latest",
      name: "calib", status: "completed"
    )
  end

  # confidences: array of [confidence_or_nil, correct]
  def record(pairs)
    pairs.each_with_index do |(confidence, correct), index|
      sample = @dataset.samples.create!(
        input_data: { "description" => "txn #{index}" },
        expected_output: { "category_name" => "Coffee" },
        difficulty: "easy"
      )
      metadata = confidence.nil? ? {} : { "confidence" => confidence }
      @run.results.create!(
        sample: sample,
        actual_output: { "category_name" => correct ? "Coffee" : "Rent" },
        correct: correct,
        metadata: metadata
      )
    end
  end

  test "reports unsupported when the provider states no confidence" do
    record([ [ nil, true ], [ nil, false ] ])

    calibration = Eval::Metrics::Calibration.new(@run)

    # A provider that reports nothing is unmeasurable, not badly calibrated —
    # the two must not be conflated.
    assert_not calibration.supported?
    assert_equal({ supported: false }, calibration.to_h)
    assert_nil calibration.expected_calibration_error
    assert_not calibration.overconfident?
    assert_match(/cannot be measured/, calibration.to_table)
  end

  test "a perfectly calibrated provider has no calibration error" do
    # Claims 0.9 in one bucket and is right 90% of the time there.
    record(Array.new(9) { [ 0.9, true ] } + [ [ 0.9, false ] ])

    calibration = Eval::Metrics::Calibration.new(@run)

    assert calibration.supported?
    assert_equal 10, calibration.sample_count
    assert_in_delta 0.0, calibration.expected_calibration_error, 0.0001
    assert_not calibration.overconfident?
  end

  test "flags a provider whose confidence outruns its accuracy" do
    # Claims 0.95 while being right half the time — the dangerous direction,
    # because this is what would auto-apply a wrong category.
    record(Array.new(5) { [ 0.95, true ] } + Array.new(5) { [ 0.95, false ] })

    calibration = Eval::Metrics::Calibration.new(@run)

    assert calibration.overconfident?
    assert_in_delta 0.45, calibration.expected_calibration_error, 0.0001

    bucket = calibration.curve.sole
    assert_equal "0.9-1.0", bucket[:range]
    assert_in_delta 0.5, bucket[:accuracy], 0.0001
    assert_in_delta(-0.45, bucket[:gap], 0.0001)
  end

  test "underconfidence is measured but not flagged as dangerous" do
    record(Array.new(10) { [ 0.5, true ] })

    calibration = Eval::Metrics::Calibration.new(@run)

    assert_in_delta 0.5, calibration.expected_calibration_error, 0.0001
    assert_not calibration.overconfident?, "being right more often than claimed is safe"
  end

  test "buckets predictions by stated confidence" do
    record([ [ 0.15, false ], [ 0.55, true ], [ 0.95, true ], [ 1.0, true ] ])

    ranges = Eval::Metrics::Calibration.new(@run).curve.map { |b| b[:range] }

    # 1.0 belongs in the top bucket rather than falling off the end.
    assert_equal [ "0.1-0.2", "0.5-0.6", "0.9-1.0" ], ranges
    assert_equal 2, Eval::Metrics::Calibration.new(@run).curve.last[:count]
  end

  test "ignores samples with no confidence alongside those that have one" do
    record([ [ 0.9, true ], [ nil, false ], [ 0.9, true ] ])

    calibration = Eval::Metrics::Calibration.new(@run)

    assert_equal 2, calibration.sample_count
    assert_in_delta 1.0, calibration.curve.sole[:accuracy], 0.0001
  end
end
