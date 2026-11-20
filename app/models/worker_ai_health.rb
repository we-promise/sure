# frozen_string_literal: true

require "socket"

# Stores and reads short-lived, worker-originated AI configuration/liveness
# results so System health -> AI status can show what a Sidekiq worker
# actually resolves and can reach, not just the web process (#3169).
#
# AiHealth (and the page built on it) proves only that the `web` process
# resolved a valid-looking configuration and could reach the provider from
# its own network context. Most AI workloads -- assistant responses, PDF
# processing, embeddings, auto-categorization, merchant detection -- run in
# Sidekiq `worker` processes instead, which can differ in environment, DNS,
# proxy, network policy, credentials, or model availability. A passing web
# check says nothing about whether those actually work.
#
# A single queued WorkerAiHealthCheckJob only verifies whichever one worker
# process dequeues it -- Sidekiq doesn't broadcast to every process, so this
# is explicitly *not* full-fleet coverage. #recent keeps a small bounded
# history keyed by process identity so an operator who runs the check a few
# times (or across a few replicas) can see more than one process's result,
# but a `passing` entry only ever describes the process named on it.
class WorkerAiHealth
  CACHE_KEY = "worker_ai_health/results/v1"

  # How long a recorded result is kept in the shared store at all. Chosen to
  # comfortably outlive an operator clicking through a few checks in one
  # sitting without piling up results from workers that no longer exist.
  RETENTION = 15.minutes

  # A result older than this still displays (so a slow investigation doesn't
  # lose context), but reads as :stale rather than :passing/:failing --
  # "verification describes what new job executions will resolve", not a
  # live guarantee about the process that produced it.
  STALE_AFTER = 5.minutes

  # Bounds how many distinct worker processes' results are retained at once,
  # so a churning fleet (deploys, autoscaling) can't grow this without limit.
  MAX_RESULTS = 5

  # One worker process's configuration fingerprint and probe outcomes. Only
  # non-secret fields: redacted endpoints (AiHealth already redacts these),
  # model/adapter names, and probe statuses -- never a raw credential.
  Snapshot = Data.define(
    :process_identity, :hostname, :pid, :checked_at,
    :effective_provider, :llm_model, :llm_endpoint, :llm_request_timeout,
    :function_calling_status,
    :vector_store_adapter, :embedding_model, :embedding_endpoint, :embedding_dimensions,
    :llm_status, :vector_store_status,
    :failure_codes
  ) do
    def stale?
      checked_at.nil? || checked_at < WorkerAiHealth::STALE_AFTER.ago
    end

    # Most-specific-first: a stale result can't be trusted as passing or
    # failing regardless of what it recorded at the time.
    def status
      return :stale if stale?
      return :failing if failure_codes.present?
      return :failing if llm_status.in?(%i[not_configured failing]) || vector_store_status.in?(%i[not_configured failing])
      return :failing if function_calling_status.in?(%i[unavailable unsupported failing])

      :passing
    end

    def passing?
      status == :passing
    end

    def failing?
      status == :failing
    end

    # Compares this worker's *effective* configuration against a web-side
    # AiHealth snapshot. Endpoints on both sides are already redacted by
    # AiHealth, so this never needs (or exposes) a credential to compare.
    def matches_web?(ai_health)
      effective_provider == ai_health.effective_llm_provider &&
        llm_model == ai_health.llm_model &&
        llm_endpoint == ai_health.llm_endpoint &&
        llm_request_timeout == ai_health.llm_request_timeout &&
        vector_store_adapter == ai_health.vector_store_adapter &&
        embedding_model == ai_health.embedding_model &&
        embedding_endpoint == ai_health.embedding_endpoint &&
        embedding_dimensions == ai_health.embedding_dimensions
    end
  end

  class << self
    # Records (or replaces) the calling process's result. Keyed by process
    # identity so repeated checks from the same worker update in place
    # instead of accumulating, while different processes coexist up to
    # MAX_RESULTS.
    #
    # Concurrent writes from two processes checking at nearly the same
    # instant can race (read-modify-write on one cache key) and the loser's
    # result is dropped for that round. Acceptable here: this is an
    # operator-triggered, low-frequency action, not a hot path, and a
    # dropped write just means running the check again.
    def record!(snapshot, cache: Rails.cache)
      results = recent(cache: cache).reject { |r| r.process_identity == snapshot.process_identity }
      results = [ snapshot, *results ].first(MAX_RESULTS)
      # Don't set expires_in here; let individual entries expire via checked_at time
      cache.write(CACHE_KEY, results)
      snapshot
    end

    # Every recorded result, most-recently-checked first. Entries beyond
    # RETENTION age out of the cache entirely; entries within it but past
    # STALE_AFTER are still returned (status: :stale) so an operator can see
    # a worker went quiet rather than the section going empty.
    def recent(cache: Rails.cache)
      results = Array(cache.read(CACHE_KEY))
      # Filter out entries older than RETENTION
      results = results.select { |r| r.checked_at && r.checked_at > RETENTION.ago }
      results.sort_by { |r| r.checked_at || Time.at(0) }.reverse
    end

    # Stable identity for "this OS process" -- hostname:pid. Good enough to
    # distinguish workers across a fleet and to let repeated checks from the
    # same process update one entry rather than duplicating it. Not a
    # cryptographic identity; it doesn't need to be for an operator-facing
    # display.
    def current_process_identity
      "#{Socket.gethostname}:#{Process.pid}"
    end

    # Enqueues an asynchronous worker-side check without blocking the caller.
    def request_check!
      WorkerAiHealthCheckJob.perform_later
    end
  end
end
