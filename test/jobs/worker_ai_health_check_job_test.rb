require "test_helper"

class WorkerAiHealthCheckJobTest < ActiveSupport::TestCase
  AI_ENVIRONMENT = %w[
    OPENAI_ACCESS_TOKEN OPENAI_URI_BASE OPENAI_MODEL
    ANTHROPIC_ACCESS_TOKEN ANTHROPIC_API_KEY VECTOR_STORE_PROVIDER
  ].index_with(nil).freeze

  setup do
    Setting.stubs(:llm_provider).returns("openai")
    Setting.stubs(:openai_access_token).returns(nil)
    Setting.stubs(:openai_uri_base).returns(nil)
    Setting.stubs(:openai_model).returns(nil)
    Setting.stubs(:anthropic_access_token).returns(nil)
    @cache = ActiveSupport::Cache::MemoryStore.new
    Rails.stubs(:cache).returns(@cache)
  end

  test "records a passing snapshot identifying this process" do
    stub_probes(status: :passing)

    with_ai_environment("OPENAI_ACCESS_TOKEN" => "sk-secret") do
      WorkerAiHealthCheckJob.perform_now
    end

    results = WorkerAiHealth.recent
    assert_equal 1, results.size

    snapshot = results.first
    assert_equal WorkerAiHealth.current_process_identity, snapshot.process_identity
    assert_equal Socket.gethostname, snapshot.hostname
    assert_equal Process.pid, snapshot.pid
    assert_equal :openai, snapshot.effective_provider
    assert snapshot.passing?
  end

  test "never persists or logs the raw access token" do
    stub_probes(status: :passing)

    with_ai_environment("OPENAI_ACCESS_TOKEN" => "sk-super-secret") do
      WorkerAiHealthCheckJob.perform_now
    end

    snapshot = WorkerAiHealth.recent.first
    refute_includes snapshot.to_h.values.map(&:to_s).join, "sk-super-secret"
  end

  test "a failing probe is recorded and written to the debug log" do
    stub_probes(status: :failing, failure_code: :model_not_available)

    with_ai_environment("OPENAI_ACCESS_TOKEN" => "sk-secret") do
      WorkerAiHealthCheckJob.perform_now
    end

    snapshot = WorkerAiHealth.recent.first
    assert snapshot.failing?
    assert_includes snapshot.failure_codes, :model_not_available

    entry = DebugLogEntry.where(category: "ai_health_worker").last
    assert_equal "error", entry.level
    assert_match(/AI health worker check failed/, entry.message)
    assert_equal WorkerAiHealth.current_process_identity, entry.metadata["process_identity"]
    assert_no_match(/sk-secret/, entry.to_json)
  end

  test "a passing probe does not write to the debug log" do
    stub_probes(status: :passing)

    with_ai_environment("OPENAI_ACCESS_TOKEN" => "sk-secret") do
      assert_no_difference -> { DebugLogEntry.where(category: "ai_health_worker").count } do
        WorkerAiHealthCheckJob.perform_now
      end
    end
  end

  test "probes with an isolated cache instead of the shared web-facing one" do
    # The defining property this job needs (#3169): its probes must never
    # read back a result a *web* AiHealth.new(probe_cache: Rails.cache) call
    # cached, and must never leave one behind for a web request to reuse.
    # Asserting the exact cache instance passed to AiHealth.new is a more
    # direct proof of that than exercising real HTTP through every probe
    # type, and doesn't need every probe stubbed to avoid unrelated
    # WebMock failures.
    AiHealth.expects(:new).with(run_probes: true, probe_cache: instance_of(ActiveSupport::Cache::NullStore))
            .returns(stub_ai_health(status: :passing))

    WorkerAiHealthCheckJob.perform_now

    assert WorkerAiHealth.recent.first.passing?
  end

  private
    def stub_probes(status:, failure_code: nil)
      passing = AiHealth::Probe::Result.new(status: :passing, checked_at: Time.current, failure_code: nil, http_status: nil)
      target = AiHealth::Probe::Result.new(status: status, checked_at: Time.current, failure_code: failure_code, http_status: nil)

      AiHealth::Probe.any_instance.stubs(:llm).returns(target)
      AiHealth::Probe.any_instance.stubs(:function_calling).returns(passing)
      AiHealth::Probe.any_instance.stubs(:pdf_text_extraction).returns(passing)
      AiHealth::Probe.any_instance.stubs(:pdf_vision_processing).returns(passing)
      AiHealth::Probe.any_instance.stubs(:openai_vector_store).returns(passing)
      AiHealth::Probe.any_instance.stubs(:pgvector).returns(passing)
      AiHealth::Probe.any_instance.stubs(:embedding).returns(passing)
    end

    # A minimal stand-in for AiHealth exposing only what the job reads,
    # for the cache-isolation test above where the real probing pipeline
    # (and everything it would call out to) isn't the point being proven.
    def stub_ai_health(status:)
      probe_result = AiHealth::Probe::Result.new(status: status, checked_at: Time.current, failure_code: nil, http_status: nil)
      not_configured = AiHealth::Probe.not_configured

      OpenStruct.new(
        effective_llm_provider: :openai,
        llm_model: "gpt-4.1",
        llm_endpoint: "https://api.openai.com/v1",
        function_calling_status: :supported,
        vector_store_adapter: nil,
        embedding_model: nil,
        embedding_endpoint: nil,
        embedding_dimensions: nil,
        llm_status: status,
        vector_store_status: :missing,
        llm_probe: probe_result,
        function_calling_probe: probe_result,
        pdf_text_extraction_probe: not_configured,
        pdf_vision_processing_probe: not_configured,
        vector_store_probe: not_configured,
        embedding_probe: not_configured
      )
    end

    def with_ai_environment(overrides = {}, &block)
      ClimateControl.modify(AI_ENVIRONMENT.merge(overrides), &block)
    end
end
