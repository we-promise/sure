require "test_helper"

class SidekiqConfigTest < ActiveSupport::TestCase
  AI_JOBS = {
    AssistantResponseJob => "ai_high_priority",
    AutoDetectMerchantsJob => "ai_low_priority",
    AutoCategorizeJob => "ai_low_priority",
    EnhanceProviderMerchantsJob => "ai_low_priority",
    ProcessPdfJob => "ai_low_priority",
    GenerateInsightsJob => "ai_low_priority"
  }.freeze

  test "the ai capsule serves the AI queues in strict order, apart from the default capsule" do
    with_env_overrides("RAILS_MAX_THREADS" => nil, "RAILS_AI_MAX_THREADS" => nil) do
      config = sidekiq_config

      assert_equal 2, config[:concurrency]
      assert_equal 1, config.dig(:capsules, :ai, :concurrency)
      assert_equal %w[ai_high_priority ai_low_priority], config.dig(:capsules, :ai, :queues)
      assert_empty config[:queues].map(&:first) & config.dig(:capsules, :ai, :queues)
    end
  end

  test "AI jobs run on the ai capsule's queues, which SidekiqHealth knows" do
    AI_JOBS.each { |job, queue| assert_equal queue, job.queue_name, job.name }
    assert_equal sidekiq_config.dig(:capsules, :ai, :queues), SidekiqHealth::AI_QUEUES
  end

  private
    def sidekiq_config
      erb = ERB.new(Rails.root.join("config/sidekiq.yml").read, trim_mode: "-")
      YAML.safe_load(erb.result, permitted_classes: [ Symbol ], aliases: true).deep_symbolize_keys
    end
end
