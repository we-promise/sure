require "test_helper"

class SidekiqConfigTest < ActiveSupport::TestCase
  test "chat has a capsule of its own; the ai capsule runs the other AI queues in strict order, apart from the default capsule" do
    with_env_overrides("RAILS_MAX_THREADS" => nil, "RAILS_AI_MAX_THREADS" => nil) do
      config = sidekiq_config

      assert_equal 2, config[:concurrency]
      assert_equal({ concurrency: 1, queues: %w[ai_interactive] }, config.dig(:capsules, :ai_chat))
      assert_equal 1, config.dig(:capsules, :ai, :concurrency)
      assert_equal %w[ai_high_priority ai_prompt ai_background ai_low_priority], config.dig(:capsules, :ai, :queues)
    end
  end

  test "RAILS_AI_MAX_THREADS sizes both AI capsules, and 0 leaves both AI capsules out" do
    with_env_overrides("RAILS_MAX_THREADS" => "5", "RAILS_AI_MAX_THREADS" => "2") do
      assert_equal 3, sidekiq_config[:concurrency]
      assert_equal 2, sidekiq_config.dig(:capsules, :ai, :concurrency)
      assert_equal 2, sidekiq_config.dig(:capsules, :ai_chat, :concurrency)
    end

    with_env_overrides("RAILS_MAX_THREADS" => "5", "RAILS_AI_MAX_THREADS" => "0") do
      assert_equal 5, sidekiq_config[:concurrency]
      assert_nil sidekiq_config[:capsules]
    end
  end

  # Ai::Capsule trusts the queue name: a job on these queues runs only in an AI capsule.
  test "the AI capsules poll exactly the AI queues, and the default capsule none of them" do
    config = sidekiq_config

    assert_equal Ai::Routes.ai_queues.sort, config[:capsules].values.flat_map { _1[:queues] }.uniq.sort
    assert_empty config[:queues].map(&:first) & Ai::Routes.ai_queues
  end

  private
    def sidekiq_config
      erb = ERB.new(Rails.root.join("config/sidekiq.yml").read, trim_mode: "-")
      YAML.safe_load(erb.result, permitted_classes: [ Symbol ], aliases: true).deep_symbolize_keys
    end
end
