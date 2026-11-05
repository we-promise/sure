class DestroyJob < ApplicationJob
  queue_as :low_priority
  # Inherits enqueue_after_transaction_commit = true from ApplicationJob. (This
  # previously read `= :never`, the removed Rails 7.2 symbol API; under 8.1 that
  # symbol is truthy, so it already deferred — the explicit line was dead and
  # misleading.) Deferring is correct here: destroy after the enclosing
  # transaction commits, never against an uncommitted/rolled-back record.

  # A deadlock (say, with a sync writing to the same account) is transient, so
  # it is retried with growing waits (about 3s, 18s, 83s, 258s) so a long sync
  # can finish first. Once the attempts run out it is handled like any other
  # failure.
  retry_on ActiveRecord::Deadlocked, wait: :polynomially_longer, attempts: 5 do |job, error|
    job.send(:handle_failure, job.arguments.first, error)
  end

  def perform(model)
    # destroy returns false instead of raising when a callback aborts it.
    model.destroy || raise(ActiveRecord::RecordNotDestroyed.new("#{model.class.name} #{model.try(:id)} was not destroyed", model))
  rescue ActiveRecord::Deadlocked => e
    # Once the row is gone (a deadlock in an after-commit step) a retry could not
    # load the record and would be discarded, so report it now.
    model.destroyed? ? handle_failure(model, e) : raise
  rescue => e
    handle_failure(model, e)
  end

  private
    def handle_failure(model, error)
      report_failure(model, error)
    ensure
      restore(model) unless model.destroyed?
    end

    # Lets the user try again by resetting the state. update_column skips
    # validations, as in DestroyableLater. Anything raised here (a validation
    # that depends on the flag, or a partial unique index the flag gates) would
    # send the job into Sidekiq's retries, failing and reporting each time.
    def restore(model)
      if model.is_a?(Account)
        # Account#destroy has usually restored it already; this call then
        # finds it disabled and does nothing.
        model.restore_after_failed_destroy
      elsif model.respond_to?(:scheduled_for_deletion)
        model.update_column(:scheduled_for_deletion, false)
      end
    rescue ActiveRecord::ActiveRecordError => e
      report_failure(model, e)
    end

    # Apart from deadlocks, a failed destroy ends the job instead of retrying,
    # so this is the only trace of why the record is still there.
    def report_failure(model, error)
      Rails.logger.error("DestroyJob failed for #{model.class.name} #{model.try(:id)}: #{error.class}: #{error.message}")
      Sentry.capture_exception(error) { |scope| scope.set_tags(record_type: model.class.name, record_id: model.try(:id)) } if defined?(Sentry)

      DebugLogEntry.capture(
        category: "background_jobs",
        level: "error",
        message: "Failed to delete #{model.class.name} #{model.try(:id)}: #{error.class}",
        source: self.class.name,
        **log_context(model),
        metadata: {
          record_type: model.class.name,
          record_id: model.try(:id),
          error_class: error.class.name,
          error_message: error.message.to_s.truncate(500),
          # Why a callback aborted the destroy, for RecordNotDestroyed.
          record_errors: error.try(:record).try(:errors)&.full_messages.presence,
          backtrace: error.backtrace&.first(5)
        }
      )
    end

    # An error raised after the delete committed (an after_commit callback)
    # leaves no row to link, and the account_id foreign key would reject it.
    def log_context(model)
      case model
      when Account
        model.destroyed? ? { family_id: model.family_id } : { account: model }
      when Family
        model.destroyed? ? {} : { family: model }
      else
        family = model.try(:family)
        context = family.is_a?(Family) ? { family: family } : {}
        context[:provider_key] = model.class.name.delete_suffix("Item").underscore if model.class.name.end_with?("Item")
        context
      end
    end
end
