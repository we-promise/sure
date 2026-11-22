require "test_helper"

class EmbeddedSidekiqTest < ActiveSupport::TestCase
  test "applies sidekiq.yml queues, weights and the ai capsule like the CLI" do
    with_env_overrides("RAILS_MAX_THREADS" => nil, "RAILS_AI_MAX_THREADS" => nil) do
      config = EmbeddedSidekiq.apply(Sidekiq::Config.new, EmbeddedSidekiq.load_options)

      assert_equal 2, config.concurrency
      assert_equal({ "scheduled" => 10, "high_priority" => 4, "medium_priority" => 2, "low_priority" => 1, "default" => 1 },
        config.default_capsule.weights)

      ai = config.capsules.fetch("ai")
      assert_equal 1, ai.concurrency
      assert_equal %w[ai_high_priority ai_low_priority], ai.queues
      assert_equal :strict, ai.mode
      assert BackgroundJobHealth.one_ai_thread_worker?(config)
    end
  end
end
