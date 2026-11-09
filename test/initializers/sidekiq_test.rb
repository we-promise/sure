require "test_helper"

class SidekiqInitializerTest < ActiveSupport::TestCase
  setup do
    @previous_grace_period = Sidekiq::Cron.configuration.reschedule_grace_period
  end

  teardown do
    Sidekiq::Cron.configuration.reschedule_grace_period = @previous_grace_period
  end

  test "cron grace period defaults to 10 minutes" do
    load_initializer

    assert_equal 600, Sidekiq::Cron.configuration.reschedule_grace_period
  end

  test "cron grace period can be raised for hosts that sleep" do
    load_initializer(SIDEKIQ_CRON_GRACE_PERIOD_SECONDS: "86400")

    assert_equal 86_400, Sidekiq::Cron.configuration.reschedule_grace_period
  end

  test "an invalid cron grace period falls back to the default" do
    [ "abc", "0", "-5" ].each do |value|
      load_initializer(SIDEKIQ_CRON_GRACE_PERIOD_SECONDS: value)

      assert_equal 600, Sidekiq::Cron.configuration.reschedule_grace_period, value
    end
  end

  test "a daily run missed while the host slept is enqueued on wake only within the grace period" do
    job = Sidekiq::Cron::Job.new(name: "sidekiq_initializer_test_#{SecureRandom.hex(8)}", cron: "22 2 * * * Etc/UTC",
                                 class: "SyncAllJob", status: "enabled")
    woke_at = Time.utc(2026, 11, 9, 7, 0)

    load_initializer
    assert_not job.should_enqueue?(woke_at)

    load_initializer(SIDEKIQ_CRON_GRACE_PERIOD_SECONDS: "86400")
    assert job.should_enqueue?(woke_at)
  ensure
    job&.destroy
  end

  private
    def load_initializer(**overrides)
      with_env_overrides({ SIDEKIQ_CRON_GRACE_PERIOD_SECONDS: nil, SIDEKIQ_WEB_USERNAME: nil, SIDEKIQ_WEB_PASSWORD: nil }.merge(overrides)) do
        load Rails.root.join("config/initializers/sidekiq.rb")
      end
    end
end
