require "test_helper"

class HealthControllerTest < ActionDispatch::IntegrationTest
  setup do
    stub_healthy_sidekiq
  end

  test "reports no errors when every dependency is healthy" do
    get "/health", headers: { "User-Agent" => "project-monitor" }

    assert_response :ok
    assert_equal "application/json", response.media_type
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_equal({ "errors" => [] }, response.parsed_body)
  end

  test "answers without a session, redirect or cookie" do
    get "/health"

    assert_response :ok
    assert_nil response.headers["Location"]
    assert_nil response.cookies["session_token"]
  end

  test "reports a worker that is not running" do
    Sidekiq::ProcessSet.stubs(:new).with(false).returns([])

    get "/health"

    assert_response :service_unavailable
    assert_equal({ "errors" => [ "worker: no worker process running" ] }, response.parsed_body)
  end

  test "reports a cron scheduler that stopped enqueuing" do
    Sidekiq::Cron::Job.stubs(:all).returns([ stub(last_enqueue_time: 5.hours.ago), stub(last_enqueue_time: nil) ])

    get "/health"

    assert_response :service_unavailable
    assert_equal({ "errors" => [ "worker: no scheduled job enqueued in 5h" ] }, response.parsed_body)
  end

  test "reports jobs that are enqueued but never processed" do
    Sidekiq::Queue.stubs(:new).with("scheduled").returns(stub(latency: 0.0))
    Sidekiq::Queue.stubs(:new).with("high_priority").returns(stub(latency: 2.hours.to_f))

    get "/health"

    assert_response :service_unavailable
    assert_equal({ "errors" => [ "worker: jobs waiting 120m unprocessed" ] }, response.parsed_body)
  end

  test "reports each failing dependency" do
    Sidekiq.stubs(:redis).raises(RedisClient::CannotConnectError, "Connection refused")
    Sidekiq::ProcessSet.stubs(:new).with(false).raises(RedisClient::CannotConnectError, "Connection refused")

    get "/health"

    assert_response :service_unavailable
    assert_equal({ "errors" => [ "redis: check failed", "worker: check failed" ] }, response.parsed_body)
  end

  test "never publishes what a failing dependency said, only logs it" do
    secret = "postgres://admin:hunter2@db.internal:5432/prod" # pipelock:ignore Credential in URL
    ActiveRecord::Base.connection_pool.stubs(:with_connection).raises(ActiveRecord::ConnectionNotEstablished, secret)
    Rails.logger.expects(:error).with(regexp_matches(/hunter2/))

    get "/health"

    assert_response :service_unavailable
    assert_equal '{"errors":["db: check failed"]}', response.body
    %w[hunter2 admin db.internal 5432].each { |fragment| assert_not_includes response.body, fragment }
  end

  test "still returns the JSON shape when the checks themselves crash" do
    HealthCheck.stubs(:errors).raises(ThreadError, "can't create Thread")

    get "/health"

    assert_response :service_unavailable
    assert_equal({ "errors" => [ "health: check failed" ] }, response.parsed_body)
  end

  private
    def stub_healthy_sidekiq
      Sidekiq.stubs(:redis).returns("PONG")
      Sidekiq::ProcessSet.stubs(:new).with(false).returns([ { "queues" => [ "scheduled", "high_priority" ] } ])
      Sidekiq::Cron::Job.stubs(:all).returns([ stub(last_enqueue_time: 10.minutes.ago) ])
      Sidekiq::Queue.stubs(:new).returns(stub(latency: 0.0))
    end
end
