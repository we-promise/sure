require "test_helper"

class Eval::Reporters::RecommendationTest < ActiveSupport::TestCase
  setup do
    @dataset = Eval::Dataset.create!(
      name: "test_rec_#{SecureRandom.hex(4)}",
      eval_type: "categorization",
      version: "1.0"
    )
    @sample_count = 0
  end

  def run_for(provider, model, metrics: {}, status: "completed")
    Eval::Run.create!(
      dataset: @dataset, provider: provider, model: model,
      name: "#{provider}_#{model}_#{SecureRandom.hex(2)}",
      status: status, metrics: metrics
    )
  end

  # Builds `wins` samples the candidate alone got right, `losses` the baseline
  # alone got right, and `agreed` both got right.
  def outcome(baseline, candidate, wins:, losses:, agreed:)
    add = lambda do |base_ok, cand_ok, count|
      count.times do
        sample = @dataset.samples.create!(
          input_data: { "description" => "txn #{@sample_count += 1}" },
          expected_output: { "category_name" => "Coffee" },
          difficulty: "easy"
        )
        baseline.results.create!(sample: sample, correct: base_ok,
                                 actual_output: { "category_name" => base_ok ? "Coffee" : "Rent" })
        candidate.results.create!(sample: sample, correct: cand_ok,
                                  actual_output: { "category_name" => cand_ok ? "Coffee" : "Travel" })
      end
    end

    add.call(false, true, wins)
    add.call(true, false, losses)
    add.call(true, true, agreed)
  end

  def recommend(baseline, candidate)
    Eval::Reporters::Recommendation.new(baseline: baseline, candidate: candidate)
  end

  test "a two-sample accuracy edge over 200 samples is reported as a tie" do
    # The real measurement: Jev 192/200, claude-sonnet-5 190/200. Calling that a
    # win would be actively misleading, so the verdict must not be "replace".
    baseline = run_for("openai", "claude-sonnet-5", metrics: { "avg_latency_ms" => 1241 })
    candidate = run_for("jev", "jev-latest", metrics: { "avg_latency_ms" => 78 })
    outcome(baseline, candidate, wins: 6, losses: 4, agreed: 186)

    result = recommend(baseline, candidate).to_h

    assert_not_equal "replace", result[:verdict]
    assert result[:p_value] > 0.05, "6 wins against 4 losses is noise, not signal"
    assert_match(/statistically indistinguishable/, result[:reasons].join(" "))
  end

  test "a tie plus a large speed advantage is worth shadowing" do
    baseline = run_for("openai", "claude-sonnet-5", metrics: { "avg_latency_ms" => 1241 })
    candidate = run_for("jev", "jev-latest", metrics: { "avg_latency_ms" => 78 })
    outcome(baseline, candidate, wins: 6, losses: 4, agreed: 186)

    result = recommend(baseline, candidate).to_h

    assert_equal "shadow", result[:verdict]
    assert_match(/15\.9x faster/, result[:reasons].join(" "))
  end

  test "a tie with no other advantage is not worth switching to" do
    baseline = run_for("openai", "gpt-4o", metrics: { "avg_latency_ms" => 100 })
    candidate = run_for("jev", "jev-latest", metrics: { "avg_latency_ms" => 95 })
    outcome(baseline, candidate, wins: 5, losses: 5, agreed: 90)

    result = recommend(baseline, candidate).to_h

    assert_equal "skip", result[:verdict]
    assert_match(/no measurable advantage/, result[:reasons].join(" "))
  end

  test "replace requires strong evidence and enough samples" do
    baseline = run_for("openai", "gpt-4o", metrics: { "avg_latency_ms" => 300 })
    candidate = run_for("jev", "jev-latest", metrics: { "avg_latency_ms" => 80 })
    outcome(baseline, candidate, wins: 20, losses: 2, agreed: 78)

    result = recommend(baseline, candidate).to_h

    assert_equal "replace", result[:verdict]
    assert result[:p_value] < 0.01
  end

  test "the same strong advantage on a small sample only earns a shadow" do
    baseline = run_for("openai", "gpt-4o", metrics: { "avg_latency_ms" => 300 })
    candidate = run_for("jev", "jev-latest", metrics: { "avg_latency_ms" => 80 })
    outcome(baseline, candidate, wins: 20, losses: 2, agreed: 38)

    result = recommend(baseline, candidate).to_h

    assert_equal "shadow", result[:verdict]
    assert_match(/thin/, result[:reasons].join(" "))
  end

  test "a significantly worse candidate is skipped" do
    baseline = run_for("openai", "gpt-4o", metrics: { "avg_latency_ms" => 300 })
    candidate = run_for("jev", "jev-latest", metrics: { "avg_latency_ms" => 80 })
    outcome(baseline, candidate, wins: 2, losses: 20, agreed: 78)

    result = recommend(baseline, candidate).to_h

    assert_equal "skip", result[:verdict]
    assert_match(/significantly worse/, result[:reasons].join(" "))
  end

  test "an errored run is rejected rather than scored" do
    # A dead model slug records every sample as incorrect, which would otherwise
    # read as a real 0% rather than a broken measurement.
    baseline = run_for("openai", "gpt-4o")
    candidate = run_for("jev", "jev-latest", metrics: { "samples_errored" => 50 })
    outcome(baseline, candidate, wins: 0, losses: 50, agreed: 50)

    result = recommend(baseline, candidate).to_h

    assert_equal "skip", result[:verdict]
    assert_match(/errored/, result[:reasons].join(" "))
  end

  test "too few samples yields shadow rather than a verdict either way" do
    baseline = run_for("openai", "gpt-4o")
    candidate = run_for("jev", "jev-latest")
    outcome(baseline, candidate, wins: 5, losses: 0, agreed: 5)

    result = recommend(baseline, candidate).to_h

    assert_equal "shadow", result[:verdict]
    assert_match(/too few to judge/, result[:reasons].join(" "))
  end

  test "one-sided cost instrumentation is stated, never read as free" do
    baseline = run_for("openai", "gpt-4o", metrics: { "avg_latency_ms" => 100 })
    candidate = run_for("jev", "jev-latest", metrics: { "avg_latency_ms" => 95 })
    outcome(baseline, candidate, wins: 5, losses: 5, agreed: 90)
    candidate.results.update_all(cost: 0.000031)

    reasons = recommend(baseline, candidate).to_h[:reasons].join(" ")

    assert_match(/cost comparison unavailable/, reasons)
    assert_match(/baseline records none/, reasons)
  end

  test "an incomplete run is not scored" do
    baseline = run_for("openai", "gpt-4o")
    candidate = run_for("jev", "jev-latest", status: "failed")
    outcome(baseline, candidate, wins: 5, losses: 5, agreed: 90)

    result = recommend(baseline, candidate).to_h

    assert_equal "skip", result[:verdict]
    assert_match(/did not complete/, result[:reasons].join(" "))
  end

  test "identical answers throughout produce no signal" do
    baseline = run_for("openai", "gpt-4o", metrics: { "avg_latency_ms" => 100 })
    candidate = run_for("jev", "jev-latest", metrics: { "avg_latency_ms" => 100 })
    outcome(baseline, candidate, wins: 0, losses: 0, agreed: 100)

    result = recommend(baseline, candidate).to_h

    assert_equal 1.0, result[:p_value]
    assert_equal "skip", result[:verdict]
  end
end
