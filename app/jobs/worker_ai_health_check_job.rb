# frozen_string_literal: true

# Runs the same bounded, non-destructive AI liveness probes AiHealth runs for
# the web admin page, but from inside a Sidekiq worker process, and records
# the result for System health -> AI status to display (#3169).
#
# Queued on demand (WorkerAiHealth.request_check!) rather than run
# automatically: this makes real provider calls, so it should only happen
# when an operator asks for it, exactly like the web page's "Run checks
# again" button.
#
# Deliberately probes with an isolated, one-shot cache (ActiveSupport::Cache::NullStore)
# instead of the shared Rails.cache AiHealth::Probe otherwise uses. Without
# that, this job could read back a result a *web* request already cached
# (proving nothing about the worker's own network path), and its own result
# would sit in the shared cache where a subsequent web request could read it
# back as if it had checked itself. Every run is a fresh, live check with no
# footprint left in the shared probe cache either way.
class WorkerAiHealthCheckJob < ApplicationJob
  # Admin-triggered and its own result is what the operator is waiting on,
  # so it shouldn't sit behind routine background work.
  queue_as :high_priority

  def perform
    ai_health = AiHealth.new(run_probes: true, probe_cache: ActiveSupport::Cache::NullStore.new)

    snapshot = WorkerAiHealth::Snapshot.new(
      process_identity: WorkerAiHealth.current_process_identity,
      hostname: Socket.gethostname,
      pid: Process.pid,
      checked_at: Time.current,
      effective_provider: ai_health.effective_llm_provider,
      llm_model: ai_health.llm_model,
      llm_endpoint: ai_health.llm_endpoint,
      llm_request_timeout: ai_health.llm_request_timeout,
      function_calling_status: ai_health.function_calling_status,
      vector_store_adapter: ai_health.vector_store_adapter,
      embedding_model: ai_health.embedding_model,
      embedding_endpoint: ai_health.embedding_endpoint,
      embedding_dimensions: ai_health.embedding_dimensions,
      llm_status: ai_health.llm_status,
      vector_store_status: ai_health.vector_store_status,
      failure_codes: failure_codes(ai_health)
    )

    WorkerAiHealth.record!(snapshot)
    record_failure(snapshot) if snapshot.failing?
    snapshot
  end

  private
    def failure_codes(ai_health)
      [
        ai_health.llm_probe.failure_code,
        ai_health.function_calling_probe.failure_code,
        ai_health.pdf_text_extraction_probe.failure_code,
        ai_health.pdf_vision_processing_probe.failure_code,
        ai_health.vector_store_probe.failure_code,
        ai_health.embedding_probe.failure_code
      ].compact.uniq
    end

    # Mirrors AiHealth::Probe#record_failure's destinations (Rails.logger and
    # DebugLogEntry) so a worker-side failure shows up in the same places an
    # operator already checks for a web-side one, distinguished by category
    # and the recorded process identity.
    def record_failure(snapshot)
      message = "AI health worker check failed on #{snapshot.process_identity}"
      metadata = {
        process_identity: snapshot.process_identity,
        hostname: snapshot.hostname,
        pid: snapshot.pid,
        llm_status: snapshot.llm_status,
        vector_store_status: snapshot.vector_store_status,
        function_calling_status: snapshot.function_calling_status,
        failure_codes: snapshot.failure_codes
      }

      Rails.logger.error("#{message}: #{metadata.to_json}")
      DebugLogEntry.capture(
        category: "ai_health_worker",
        level: "error",
        message: message,
        source: self.class.name,
        metadata: metadata
      )
    end
end
