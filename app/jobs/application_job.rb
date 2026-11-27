class ApplicationJob < ActiveJob::Base
  # Defer enqueuing until the surrounding Active Record transaction commits, so a
  # job is never picked up by a worker before the records it references (by
  # GlobalID) are committed and visible on the worker's connection — and is
  # dropped entirely if the transaction rolls back. Without this, a job enqueued
  # inside a transaction can be dequeued before COMMIT, fail to load its
  # arguments (ActiveJob::DeserializationError), and be silently dropped by the
  # `discard_on` below — the "stuck sync" regression for SyncJob enqueued in
  # Syncable#sync_later.
  #
  # This is the Rails 8.2 default. On 8.1 the global
  # `config.active_job.enqueue_after_transaction_commit` toggle is non-functional,
  # so we set the class attribute on the base job, which every job inherits.
  self.enqueue_after_transaction_commit = true

  retry_on ActiveRecord::Deadlocked
  discard_on ActiveJob::DeserializationError
  queue_as :low_priority # default queue

  # Seconds before a job that found its local model host busy runs again.
  BUSY_WAIT = 5..15

  # A background AI request never waits at a full local model host (Ai::Gate): the job runs again
  # in a few seconds, at the back of its queue, as often as it takes. It's the same job, so the
  # other errors' retry counts carry on.
  retry_on Ai::Error::Busy, wait: ->(_executions) { rand(BUSY_WAIT) }, attempts: :unlimited

  # A callback rather than Sidekiq middleware, so it also runs under the test adapter and
  # `perform_now`.
  around_perform :run_in_ai_capsule

  private
    # A job on an AI queue may call a model, in its queue's lane.
    def run_in_ai_capsule(&block)
      Ai::Capsule.within(queue_name) { Ai::Sequencer.with_lane(Ai::Routes.lane_for_queue(queue_name), &block) }
    end
end
