# Runs the AI health checks in a worker, where the AI work they check runs, so the admin page
# never calls a model. It stores the probe results (AiHealth::Probe#store!) and this worker's
# snapshot (WorkerAiHealth) in Ai::SharedState, then has open AI tabs reload their status.
#
# A failed probe is a result, not an error, so the job doesn't retry: "Run checks again" does.
# Two clicks run the checks twice, which is harmless, so there's no unique lock.
class Ai::ProbeJob < ApplicationJob
  STREAM = "admin_ai_health".freeze

  queue_as Ai::Routes::QUEUES.fetch(:background)
  sidekiq_options retry: false

  def perform
    WorkerAiHealth.record!(WorkerAiHealth::Snapshot.of(AiHealth.new(run_probes: true)))

    # A refresh, not new markup: each page reloads its own URL, so its tab, `?locale=` and CSRF
    # token stay its own, and `refresh: :morph` on the frame reloads the status.
    Turbo::StreamsChannel.broadcast_refresh_to(STREAM)
  end
end
