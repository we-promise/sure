# Kept for one release so a check queued before the upgrade still runs: Ai::ProbeJob runs the
# AI probes now, on its own queue.
class WorkerAiHealthCheckJob < ApplicationJob
  queue_as :high_priority

  def perform
    Ai::ProbeJob.perform_later
  end
end
