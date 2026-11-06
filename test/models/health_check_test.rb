require "test_helper"

class HealthCheckTest < ActiveSupport::TestCase
  setup do
    Sidekiq.stubs(:redis).returns("PONG")
    Sidekiq::ProcessSet.stubs(:new).with(false).returns([ {} ])
    Sidekiq::Cron::Job.stubs(:all).returns([ stub(last_enqueue_time: 10.minutes.ago) ])
    Sidekiq::Queue.stubs(:new).returns(stub(latency: 0.0))
    HealthCheck.reset
  end

  teardown do
    HealthCheck.reset
  end

  test "a hanging dependency is reported as a timeout without delaying the other checks" do
    Sidekiq.stubs(:redis).with { sleep 5 }.returns("PONG")

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    errors = HealthCheck.new(timeout: 0.2).errors
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_equal [ "redis: timeout after 200ms" ], errors
    assert_operator elapsed, :<, 4
  end

  test "a check still running from an earlier request is joined instead of started again" do
    calls = 0
    Sidekiq.stubs(:redis).with { calls += 1; sleep 1 }.returns("PONG")

    2.times { assert_includes HealthCheck.new(timeout: 0.2).errors, "redis: timeout after 200ms" }
    assert_equal 1, calls

    assert_not_includes HealthCheck.new(timeout: 3).errors, "redis: timeout after 3000ms"
    assert_equal 1, calls, "the next request picks up the result of the run already in flight"
  end

  test "the database check is bounded by a statement timeout" do
    assert_empty HealthCheck.new(timeout: 2).errors
    assert_equal "2s", ActiveRecord::Base.connection.select_value("SHOW statement_timeout")
  end

  test "a scheduler that never enqueued anything is reported" do
    Sidekiq::Cron::Job.stubs(:all).returns([ stub(last_enqueue_time: nil) ])

    assert_equal [ "worker: no scheduled job enqueued yet" ], HealthCheck.errors
  end

  test "an unexpected PING reply is reported" do
    Sidekiq.stubs(:redis).returns("LOADING")

    assert_equal [ "redis: unexpected PING reply" ], HealthCheck.errors
  end
end
