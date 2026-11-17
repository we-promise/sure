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

  test "runs on the background lane's AI queue" do
    assert_equal Ai::Routes::QUEUES.fetch(:background), Ai::ProbeJob.new.queue_name
    assert_includes Ai::Capsule::QUEUES, Ai::ProbeJob.new.queue_name
  end

  test "stores fresh results the page reads without probing, and records this worker" do
    stub_probe_answers(passing)

    with_openai_token { Ai::ProbeJob.perform_now }

    page = with_openai_token { AiHealth.new(stored_only: true) }
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

    page = with_openai_token { AiHealth.new(stored_only: true) }
    assert_equal :failing, page.llm_status
    assert_equal :no_credit, page.llm_probe.failure_code
    assert_includes WorkerAiHealth.recent.sole.failure_codes, :no_credit
  end

  test "a stored result doesn't stop the job probing again" do
    stub_probe_answers(AiHealth::Probe::Result.new(status: :failing, checked_at: 1.minute.ago, failure_code: :timeout, http_status: nil))
    with_openai_token { Ai::ProbeJob.perform_now }

    stub_probe_answers(passing)
    with_openai_token { Ai::ProbeJob.perform_now }

    assert with_openai_token { AiHealth.new(stored_only: true) }.llm_probe.passing?
  end

  # The tab's form needs a request's CSRF token, so the job sends a frame that loads itself.
  test "has open AI tabs reload their status" do
    stub_probe_answers(passing)

    broadcasts = capture_turbo_stream_broadcasts(Ai::ProbeJob::STREAM) { with_openai_token { Ai::ProbeJob.perform_now } }

    stream = broadcasts.sole
    assert_equal [ "replace", "ai_status" ], [ stream["action"], stream["target"] ]
    assert_equal Rails.application.routes.url_helpers.ai_status_admin_system_health_path,
                 stream.at_css("turbo-frame#ai_status")["src"]
  end

  private
    def passing = AiHealth::Probe::Result.new(status: :passing, checked_at: Time.current, failure_code: nil, http_status: nil)

    # Each probe's request answers `result`; the caching around it, and the store, are real.
    def stub_probe_answers(result)
      AiHealth::Probe.any_instance.stubs(:perform).returns(result)
    end

    def with_openai_token(&block)
      ClimateControl.modify(AI_ENVIRONMENT.merge("OPENAI_ACCESS_TOKEN" => "sk-secret"), &block)
    end
end
