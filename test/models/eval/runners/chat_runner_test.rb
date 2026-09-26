require "test_helper"

class Eval::Runners::ChatRunnerTest < ActiveSupport::TestCase
  setup do
    @dataset = Eval::Dataset.create!(
      name: "chat_repro_#{SecureRandom.hex(4)}", eval_type: "chat", version: "2026.09"
    )
    @run = Eval::Run.create!(
      dataset: @dataset, provider: "openai", model: "gpt-4.1", status: "pending",
      provider_config: { "reference_date" => "2024-12-01" }
    )
  end

  test "uses frozen reference date from run config" do
    runner = Eval::Runners::ChatRunner.new(@run)
    assert_includes runner.send(:build_instructions), "Today's date: 2024-12-01"
    refute_includes runner.send(:build_instructions), "Today's date: #{Date.current}" unless Date.current.iso8601 == "2024-12-01"
  end

  test "falls back to current date without override" do
    @run.update!(provider_config: {})
    assert_includes Eval::Runners::ChatRunner.new(@run).send(:build_instructions), "Today's date: #{Date.current}"
  end

  test "captures dataset version and resolved API model" do
    assert_equal "2026.09", @run.dataset_version
    @dataset.update!(version: "2026.10")
    assert_equal "2026.09", @run.reload.dataset_version
    @run.record_resolved_model!("gpt-4.1-2025-04-14")
    assert_equal "gpt-4.1-2025-04-14", @run.reload.resolved_model_snapshot
    @run.record_resolved_model!("gpt-4.1-2025-04-14")
    @run.record_resolved_model!("gpt-4.1-2026-01-01")
    assert_raises(RuntimeError) { @run.verify_model_snapshot! }
  end
end
