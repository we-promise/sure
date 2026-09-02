require "test_helper"

class WorkerAiHealthTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @cache = ActiveSupport::Cache::MemoryStore.new
  end

  test "records a snapshot and reads it back" do
    snapshot = passing_snapshot(process_identity: "host-a:1")

    WorkerAiHealth.record!(snapshot, cache: @cache)

    assert_equal [ snapshot ], WorkerAiHealth.recent(cache: @cache)
  end

  test "returns an empty list when nothing has been recorded" do
    assert_equal [], WorkerAiHealth.recent(cache: @cache)
  end

  test "recording again from the same process replaces its entry instead of duplicating" do
    first = passing_snapshot(process_identity: "host-a:1", checked_at: 2.minutes.ago)
    second = passing_snapshot(process_identity: "host-a:1", checked_at: Time.current)

    WorkerAiHealth.record!(first, cache: @cache)
    WorkerAiHealth.record!(second, cache: @cache)

    results = WorkerAiHealth.recent(cache: @cache)
    assert_equal 1, results.size
    assert_equal second, results.first
  end

  test "different processes coexist, most recently checked first" do
    older = passing_snapshot(process_identity: "host-a:1", checked_at: 2.minutes.ago)
    newer = passing_snapshot(process_identity: "host-b:2", checked_at: Time.current)

    WorkerAiHealth.record!(older, cache: @cache)
    WorkerAiHealth.record!(newer, cache: @cache)

    assert_equal [ newer, older ], WorkerAiHealth.recent(cache: @cache)
  end

  test "bounds the number of retained results" do
    (WorkerAiHealth::MAX_RESULTS + 2).times do |i|
      WorkerAiHealth.record!(
        passing_snapshot(process_identity: "host-#{i}:#{i}", checked_at: i.minutes.ago),
        cache: @cache
      )
    end

    assert_equal WorkerAiHealth::MAX_RESULTS, WorkerAiHealth.recent(cache: @cache).size
  end

  test "a snapshot without a checked_at is stale" do
    snapshot = passing_snapshot(checked_at: nil)

    assert snapshot.stale?
    assert_equal :stale, snapshot.status
  end

  test "a snapshot older than STALE_AFTER is stale even if it recorded passing" do
    snapshot = passing_snapshot(checked_at: (WorkerAiHealth::STALE_AFTER + 1.second).ago)

    assert snapshot.stale?
    assert_equal :stale, snapshot.status
  end

  test "a fresh snapshot with no failures and nothing failing is passing" do
    snapshot = passing_snapshot(checked_at: Time.current)

    assert_not snapshot.stale?
    assert_equal :passing, snapshot.status
    assert snapshot.passing?
    assert_not snapshot.failing?
  end

  test "any recorded failure code marks the snapshot failing regardless of individual statuses" do
    snapshot = passing_snapshot(failure_codes: [ :model_not_available ])

    assert_equal :failing, snapshot.status
    assert snapshot.failing?
  end

  test "a failing llm_status marks the snapshot failing even with no failure codes" do
    snapshot = passing_snapshot(llm_status: :failing)

    assert_equal :failing, snapshot.status
  end

  test "a failing vector_store_status marks the snapshot failing" do
    snapshot = passing_snapshot(vector_store_status: :failing)

    assert_equal :failing, snapshot.status
  end

  test "unsupported or failing function calling marks the snapshot failing" do
    assert_equal :failing, passing_snapshot(function_calling_status: :unsupported).status
    assert_equal :failing, passing_snapshot(function_calling_status: :failing).status
  end

  test "matches_web? compares effective configuration field by field" do
    ai_health = fake_ai_health

    matching = passing_snapshot(
      effective_provider: :openai,
      llm_model: "gpt-4.1",
      llm_endpoint: "https://api.openai.com/v1",
      vector_store_adapter: :pgvector,
      embedding_model: "mxbai-embed-large",
      embedding_endpoint: "http://ollama:11434/v1",
      embedding_dimensions: 1024
    )
    assert matching.matches_web?(ai_health)

    mismatched = passing_snapshot(
      effective_provider: :openai,
      llm_model: "a-different-model",
      llm_endpoint: "https://api.openai.com/v1",
      vector_store_adapter: :pgvector,
      embedding_model: "mxbai-embed-large",
      embedding_endpoint: "http://ollama:11434/v1",
      embedding_dimensions: 1024
    )
    assert_not mismatched.matches_web?(ai_health)
  end

  test "matches_web? catches a request-timeout mismatch even when every other field matches" do
    ai_health = fake_ai_health

    assert passing_snapshot(llm_request_timeout: 30).matches_web?(ai_health)
    assert_not passing_snapshot(llm_request_timeout: 90).matches_web?(ai_health)
  end

  test "current_process_identity combines hostname and pid" do
    identity = WorkerAiHealth.current_process_identity

    assert_includes identity, Socket.gethostname
    assert_includes identity, Process.pid.to_s
  end

  test "request_check! enqueues the worker check job" do
    assert_enqueued_with(job: WorkerAiHealthCheckJob) do
      WorkerAiHealth.request_check!
    end
  end

  test "a snapshot never carries a credential-shaped field" do
    # Structural guard: the fields a Snapshot can hold are a fixed allowlist,
    # so there is no field for a raw token, key, or password to ever land in
    # by a future edit adding one more `ai_health.*` reader without noticing
    # it's a secret (#3169's "never persist or display raw credentials").
    disallowed = /token|secret|password|api_key|credential/i

    assert_empty WorkerAiHealth::Snapshot.members.grep(disallowed)
  end

  private
    def passing_snapshot(overrides = {})
      WorkerAiHealth::Snapshot.new(
        **{
          process_identity: "host:1",
          hostname: "host",
          pid: 1,
          checked_at: Time.current,
          effective_provider: :openai,
          llm_model: "gpt-4.1",
          llm_endpoint: "https://api.openai.com/v1",
          llm_request_timeout: 30,
          function_calling_status: :supported,
          vector_store_adapter: :pgvector,
          embedding_model: "mxbai-embed-large",
          embedding_endpoint: "http://ollama:11434/v1",
          embedding_dimensions: 1024,
          llm_status: :passing,
          vector_store_status: :passing,
          failure_codes: []
        }.merge(overrides)
      )
    end

    def fake_ai_health
      OpenStruct.new(
        effective_llm_provider: :openai,
        llm_model: "gpt-4.1",
        llm_endpoint: "https://api.openai.com/v1",
        llm_request_timeout: 30,
        vector_store_adapter: :pgvector,
        embedding_model: "mxbai-embed-large",
        embedding_endpoint: "http://ollama:11434/v1",
        embedding_dimensions: 1024
      )
    end
end
