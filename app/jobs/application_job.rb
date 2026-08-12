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
end
