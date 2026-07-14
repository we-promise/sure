require "sidekiq/api"

# Backs the super-admin background jobs console (/settings/background_jobs).
#
# Combines domain truth (in-flight Sync / Import / ImportSession / FamilyExport
# records across all families) with Sidekiq runtime truth (worker processes,
# queue depths, jobs currently executing) so an operator can tell a running
# job from one whose worker died and mark the latter as lost.
#
# Unlike BackgroundJobHealth this fails CLOSED: when Redis is unreachable,
# liveness is unknown and destructive actions are refused rather than the
# console pretending everything is healthy.
class BackgroundJobConsole
  OPERATIONS_LIMIT = 100

  # A record younger than this may belong to a job that is merely queued
  # behind a backlog or between Sidekiq heartbeats — refuse to touch it.
  STUCK_AFTER = 30.minutes

  Stats = Struct.new(:processes, :busy, :enqueued, :retry_size, :dead_size, :scheduled_size, :queues, keyword_init: true)

  attr_reader :stats

  def initialize
    @redis_error = false
    @running_global_ids = Set.new
    @stats = nil
    load_runtime_state
  end

  def redis_error?
    @redis_error
  end

  # In-flight operations across ALL families, newest activity first. This is
  # deliberately instance-global — the console is super-admin only.
  def operations
    @operations ||= [
      Sync.incomplete.includes(:syncable).order(updated_at: :desc).limit(OPERATIONS_LIMIT).to_a,
      Import.where(status: [ :importing, :reverting ]).includes(:family).order(updated_at: :desc).limit(OPERATIONS_LIMIT).to_a,
      ImportSession.where(status: :importing).includes(:family).order(updated_at: :desc).limit(OPERATIONS_LIMIT).to_a,
      FamilyExport.where(status: [ :pending, :processing ]).includes(:family).order(updated_at: :desc).limit(OPERATIONS_LIMIT).to_a
    ].flatten.sort_by(&:updated_at).reverse
  end

  # A record's job is visibly executing right now (its GlobalID appears in a
  # worker's payload). False also means "unknown" when redis_error? is set —
  # callers must check that first for destructive decisions.
  def running?(record)
    @running_global_ids.include?(record.to_global_id.to_s)
  end

  # Safe to force-terminalize: liveness is knowable, the job is not visibly
  # executing, the record has been idle past the stuck window, and (for syncs)
  # no children are still in flight — a parent Sync legitimately has no live
  # job of its own while its children run.
  def cancellable?(record)
    return false if redis_error?
    return false if running?(record)
    return false if record.updated_at > STUCK_AFTER.ago
    return false if record.is_a?(Sync) && record.children.incomplete.exists?

    true
  end

  def self.family_for(record)
    if record.is_a?(Sync)
      syncable = record.syncable
      syncable.is_a?(Family) ? syncable : syncable&.family
    else
      record.family
    end
  end

  private
    def load_runtime_state
      processes = Sidekiq::ProcessSet.new
      sidekiq_stats = Sidekiq::Stats.new

      @stats = Stats.new(
        processes: processes.size,
        busy: processes.sum { |process| process["busy"].to_i },
        enqueued: sidekiq_stats.enqueued,
        retry_size: sidekiq_stats.retry_size,
        dead_size: sidekiq_stats.dead_size,
        scheduled_size: sidekiq_stats.scheduled_size,
        queues: Sidekiq::Queue.all.map { |queue| { name: queue.name, size: queue.size, latency: queue.latency.round(1) } }
      )

      @running_global_ids = collect_running_global_ids
    rescue => e
      Rails.logger.warn("BackgroundJobConsole: Sidekiq state unavailable: #{e.class}: #{e.message}")
      @redis_error = true
      @stats = nil
      @running_global_ids = Set.new
    end

    # All jobs are ActiveJob-wrapped, so record references appear in worker
    # payloads as serialized GlobalIDs ({"_aj_globalid" => "gid://..."}).
    def collect_running_global_ids
      ids = Set.new

      Sidekiq::Workers.new.each do |_process_id, _thread_id, work|
        payload = work.respond_to?(:payload) ? work.payload : work["payload"]
        payload = JSON.parse(payload) if payload.is_a?(String)
        collect_global_ids(payload, ids)
      rescue JSON::ParserError
        next
      end

      ids
    end

    def collect_global_ids(node, ids)
      case node
      when Hash
        node.each do |key, value|
          if key == "_aj_globalid" && value.is_a?(String)
            ids << value
          else
            collect_global_ids(value, ids)
          end
        end
      when Array
        node.each { |value| collect_global_ids(value, ids) }
      end
    end
end
