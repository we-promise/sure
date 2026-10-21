require "test_helper"
require "csv"

class Eval::Reporters::ComparisonReporterTest < ActiveSupport::TestCase
  setup do
    @dataset = Eval::Dataset.create!(
      name: "test_cmp_#{SecureRandom.hex(4)}",
      eval_type: "categorization",
      version: "1.0"
    )
  end

  def completed_run(provider:, model:, accuracy:, latency:, cost: 0.0)
    Eval::Run.create!(
      dataset: @dataset,
      provider: provider,
      model: model,
      name: "#{provider}_#{model}",
      status: "completed",
      metrics: { "accuracy" => accuracy, "avg_latency_ms" => latency },
      total_cost: cost,
      started_at: 1.minute.ago,
      completed_at: Time.current
    )
  end

  def jev_and_openai_runs
    [
      completed_run(provider: "jev", model: "~typesafe/jev-latest", accuracy: 96.0, latency: 71, cost: 0.0016),
      completed_run(provider: "openai", model: "gpt-4o-mini", accuracy: 91.0, latency: 240, cost: 0.0092)
    ]
  end

  test "the terminal table names the provider of each run" do
    table = Eval::Reporters::ComparisonReporter.new(jev_and_openai_runs).to_table

    assert_match(/Provider/, table)
    assert_match(/jev/, table)
    assert_match(/openai/, table)
  end

  test "distinguishes two providers serving the same model name" do
    runs = [
      completed_run(provider: "jev", model: "shared-model", accuracy: 96.0, latency: 71),
      completed_run(provider: "openai", model: "shared-model", accuracy: 80.0, latency: 240)
    ]

    summary = Eval::Reporters::ComparisonReporter.new(runs).summary

    # Keyed on model alone these two collide — the label is what tells them apart.
    assert_equal "jev:shared-model", summary[:best_accuracy][:label]
    assert_equal "jev", summary[:best_accuracy][:provider]
    assert_equal "shared-model", summary[:best_accuracy][:model]
  end

  test "summary carries provider alongside model for each category" do
    summary = Eval::Reporters::ComparisonReporter.new(jev_and_openai_runs).summary

    assert_equal "jev", summary[:best_accuracy][:provider]
    assert_equal "jev", summary[:lowest_cost][:provider]
    assert_equal "jev", summary[:fastest][:provider]
    assert_equal "jev:~typesafe/jev-latest", summary[:fastest][:label]
  end

  test "recommendation prose identifies a run by provider and model" do
    summary = Eval::Reporters::ComparisonReporter.new(jev_and_openai_runs).summary

    assert_match(/jev:~typesafe\/jev-latest/, summary[:recommendation])
  end

  test "pairwise comparisons carry provider-qualified labels" do
    comparison = Eval::Reporters::ComparisonReporter.new(jev_and_openai_runs).detailed_comparison
    pair = comparison[:comparison].sole

    assert_equal [ "jev:~typesafe/jev-latest", "openai:gpt-4o-mini" ], pair[:labels]
    assert_equal [ "~typesafe/jev-latest", "gpt-4o-mini" ], pair[:models]
  end

  test "runs are ordered by provider then model" do
    runs = [
      completed_run(provider: "openai", model: "gpt-4o-mini", accuracy: 91.0, latency: 240),
      completed_run(provider: "jev", model: "~typesafe/jev-latest", accuracy: 96.0, latency: 71)
    ]

    reporter = Eval::Reporters::ComparisonReporter.new(runs)

    assert_equal %w[jev openai], reporter.runs.map(&:provider)
  end

  test "csv output keeps its existing column set" do
    reporter = Eval::Reporters::ComparisonReporter.new(jev_and_openai_runs)

    Tempfile.create([ "comparison", ".csv" ]) do |file|
      reporter.to_csv(file.path)
      rows = CSV.read(file.path)

      assert_equal [
        "Run ID", "Model", "Provider", "Dataset", "Status",
        "Accuracy", "Precision", "Recall", "F1 Score",
        "Null Accuracy", "Hierarchical Accuracy",
        "Avg Latency (ms)", "Total Cost", "Cost Per Sample",
        "Samples Processed", "Samples Correct",
        "Duration (s)", "Run Date"
      ], rows.first
      assert_equal 3, rows.size
    end
  end

  test "returns an empty summary when nothing completed" do
    reporter = Eval::Reporters::ComparisonReporter.new([])

    assert_equal({}, reporter.summary)
    assert_equal "No runs to compare", reporter.to_table
  end
end
