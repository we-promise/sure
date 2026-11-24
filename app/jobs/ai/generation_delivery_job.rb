# The AI generation outbox's delivery (docs/proposals/v0.8/ai-generation-outbox.md): every 15
# minutes, queues again each run step that no job has touched for an hour (Ai::GenerationRun#redeliver).
# It never calls a model, so it runs on the scheduled queue, not an AI one.
class Ai::GenerationDeliveryJob < ApplicationJob
  queue_as :scheduled
  sidekiq_options lock: :until_executed, on_conflict: :log

  def perform
    Ai::GenerationRun.undelivered.find_each do |run|
      run.redeliver
    rescue StandardError => error
      # One run's requester failing to hear its give-up mustn't hold up the others.
      Rails.error.report(error, handled: true, context: { run_id: run.id, feature: run.feature })
    end
  end
end
