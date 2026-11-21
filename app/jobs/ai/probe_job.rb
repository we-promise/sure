# Runs the AI health checks in a worker, where the AI work they check runs, so the admin page
# never calls a model. It stores the probe results (AiHealth::Probe#store!) and this worker's
# snapshot (WorkerAiHealth) in Ai::SharedState, then has open AI tabs reload their status.
#
# A failed probe is a result, not an error, so the job doesn't retry: "Run checks again" does.
class Ai::ProbeJob < ApplicationJob
  STREAM = "admin_ai_health".freeze

  queue_as Ai::Routes::QUEUES.fetch(:background)
  sidekiq_options retry: false, lock: :until_executed, on_conflict: :log

  def perform
    WorkerAiHealth.record!(WorkerAiHealth::Snapshot.of(AiHealth.new(run_probes: true)))

    # A frame that loads itself, rather than the status: the tab's form needs a request's CSRF token.
    Turbo::StreamsChannel.broadcast_replace_to(
      STREAM, target: "ai_status", partial: "admin/system_health/ai_status_frame",
      locals: { src: Rails.application.routes.url_helpers.ai_status_admin_system_health_path }
    )
  end
end
