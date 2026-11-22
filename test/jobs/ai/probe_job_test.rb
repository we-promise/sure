require "test_helper"
require "turbo/broadcastable/test_helper"

class Ai::ProbeJobTest < ActiveSupport::TestCase
  # turbo-rails adds this only once Action Cable has loaded, which a test run alone may not do.
  include Turbo::Broadcastable::TestHelper

  AI_ENVIRONMENT = %w[
    OPENAI_ACCESS_TOKEN OPENAI_URI_BASE OPENAI_MODEL ANTHROPIC_ACCESS_TOKEN ANTHROPIC_API_KEY VECTOR_STORE_PROVIDER
  ].index_with(nil).freeze

  setup do
    Setting.stubs(:llm_provider).returns("openai")
    Setting.stubs(:openai_access_token).returns(nil)
    Setting.stubs(:openai_uri_base).returns(nil)
    Setting.stubs(:openai_model).returns(nil)
    Setting.stubs(:anthropic_access_token).returns(nil)
  end

  test "stores fresh results the page reads without probing, and records this worker" do
    stub_probe_answers(passing)

    with_openai_token { Ai::ProbeJob.perform_now }

    page = with_openai_token { AiHealth.new }
    assert page.llm_probe.passing?
    assert_equal :supported, page.function_calling_status
    snapshot = WorkerAiHealth.recent.sole
    assert_equal WorkerAiHealth.current_process_identity, snapshot.process_identity
    assert snapshot.passing?
    assert_not_includes snapshot.to_h.values.join, "sk-secret"
  end

  test "a failing probe is a result: the job finishes and the page shows it" do
    stub_probe_answers(AiHealth::Probe::Result.new(status: :failing, checked_at: Time.current, failure_code: :no_credit, http_status: 402))

    assert_nothing_raised { with_openai_token { Ai::ProbeJob.perform_now } }

    page = with_openai_token { AiHealth.new }
    assert_equal :failing, page.llm_status
    assert_equal :no_credit, page.llm_probe.failure_code
    assert_includes WorkerAiHealth.recent.sole.failure_codes, :no_credit
  end

  test "a stored result doesn't stop the job probing again" do
    stub_probe_answers(AiHealth::Probe::Result.new(status: :failing, checked_at: 1.minute.ago, failure_code: :timeout, http_status: nil))
    with_openai_token { Ai::ProbeJob.perform_now }

    stub_probe_answers(passing)
    with_openai_token { Ai::ProbeJob.perform_now }

    assert with_openai_token { AiHealth.new }.llm_probe.passing?
  end

  test "results written early in a run are still there when the last probe finishes" do
    AiHealth::Probe.any_instance.stubs(:perform).with { travel AiHealth::Probe.cache_ttl / 2; true }.returns(passing)

    with_openai_token { Ai::ProbeJob.perform_now }

    assert with_openai_token { AiHealth.new }.llm_probe.passing?
  end

  test "an error from a probe's request reaches the job once, not swallowed and retried" do
    attempts = 0
    AiHealth::Probe.any_instance.stubs(:perform).with { attempts += 1 }.raises(Ai::Error::Base, "busy")

    assert_raises(Ai::Error::Base) { with_openai_token { Ai::ProbeJob.perform_now } }
    assert_equal 1, attempts
  end

  test "the worker snapshot is kept for the retention window, then dropped" do
    stub_probe_answers(passing)
    with_openai_token { Ai::ProbeJob.perform_now }

    travel WorkerAiHealth::STALE_AFTER + 1.second
    assert_equal :stale, WorkerAiHealth.recent.sole.status
    travel WorkerAiHealth::RETENTION
    assert_empty WorkerAiHealth.recent
  end

  test "the page shows no worker results, rather than failing, when Redis is down" do
    Ai::SharedState.store.stubs(:read).raises(RedisClient::CannotConnectError)

    assert_empty WorkerAiHealth.recent
    assert with_openai_token { AiHealth.new }.llm_probe.not_checked?
  end

  test "when Redis refuses the writes, the job still finishes and the tabs still reload" do
    stub_probe_answers(passing)
    Ai::SharedState.store.stubs(:write).raises(RedisClient::CannotConnectError)

    broadcasts = capture_turbo_stream_broadcasts(Ai::ProbeJob::STREAM) { with_openai_token { Ai::ProbeJob.perform_now } }

    assert_equal "refresh", broadcasts.sole["action"]
  end

  test "a job on an AI queue runs inside the capsule; a job on any other queue doesn't" do
    seen = []
    job = Class.new(ApplicationJob) { define_method(:perform) { seen << [ queue_name, Ai::Capsule.inside? ] } }

    (Ai::Routes.ai_queues + %w[high_priority default]).each { job.set(queue: _1).perform_now }

    assert_equal Ai::Routes.ai_queues.map { [ _1, true ] } + [ [ "high_priority", false ], [ "default", false ] ], seen
    assert_raises(Ai::Capsule::Violation) { Ai::Capsule.check! }
    assert_nil Ai::Capsule.outside { Ai::Capsule.check! }
  end

  test "threads a job starts are inside too, and the mark is restored after a raise" do
    assert with_ai_capsule { Thread.new { Ai::Capsule.inside? }.value }
    assert_raises(RuntimeError) { with_ai_capsule { raise "boom" } }
    assert_not Ai::Capsule.inside?
  end

  test "shared state is JSON in Sidekiq's Redis, and every value must expire" do
    Ai::SharedState.store = Ai::SharedState::RedisStore.new
    key = "ai/test/#{SecureRandom.hex(4)}"

    Ai::SharedState.write(key, { "codes" => [ 1 ] }, expires_in: 0.5.seconds)

    assert_equal({ "codes" => [ 1 ] }, Ai::SharedState.read(key))
    assert_includes 1..500, Sidekiq.redis { _1.call("PTTL", key) }
    assert_raises(ArgumentError) { Ai::SharedState.write(key, [ 1 ], expires_in: nil) }
  ensure
    Ai::SharedState.delete(key)
  end

  # A refresh carries no URL, so each tab reloads its own, with its locale and CSRF token.
  test "has open AI tabs reload their status" do
    stub_probe_answers(passing)

    broadcasts = capture_turbo_stream_broadcasts(Ai::ProbeJob::STREAM) { with_openai_token { Ai::ProbeJob.perform_now } }

    stream = broadcasts.sole
    assert_equal "refresh", stream["action"]
    assert_empty stream.children
  end

  private
    def passing = AiHealth::Probe::Result.new(status: :passing, checked_at: Time.current, failure_code: nil, http_status: nil)

    # Each probe's request answers `result`; storing it, and reading it back, are real.
    def stub_probe_answers(result)
      AiHealth::Probe.any_instance.stubs(:perform).returns(result)
    end

    def with_openai_token(&block)
      ClimateControl.modify(AI_ENVIRONMENT.merge("OPENAI_ACCESS_TOKEN" => "sk-secret"), &block)
    end
end
