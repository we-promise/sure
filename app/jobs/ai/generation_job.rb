# The one job every generation feature runs in. It runs one batch, applies it through the
# requester and enqueues the rest at the back of its queue, so one family's large run takes turns
# with other families' work. The queue comes from the feature's lane (Ai::Routes.queue_for).
#
# On a failure, the transport has already retried 429s and 5xxs and the generation
# has failed over and escalated; what's left is retried later when it may pass, and discarded
# when it can't. Any other error ends the run. Either way the requester hears once, so a RuleRun
# never stays pending.
class Ai::GenerationJob < ApplicationJob
  queue_as { Ai::Routes.queue_for(arguments.first) }

  RETRIED = [ Ai::Error::RateLimited, Ai::Error::Timeout, Ai::Error::Upstream, Ai::Error::Unreachable ].freeze
  DISCARDED = [ Ai::Error::Unavailable, Ai::Error::Refused, Ai::Error::Unauthorized, Ai::Error::NoCredit,
                Ai::Error::ModelMissing, Ai::Error::ContextTooLong, Ai::Error::InvalidOutput, Ai::Error::Cancelled ].freeze

  retry_on(*RETRIED, wait: :polynomially_longer, attempts: 5) { |job, error| job.give_up(error) }
  retry_on(ActiveRecord::Deadlocked, attempts: 5) { |job, error| job.give_up(error) }
  discard_on(*DISCARDED) { |job, error| job.give_up(error) }

  # feature: a key in Ai::Requesters; args: the requester's own (`ids:` the items left); applied:
  # the count the earlier batches applied; answered_before: whether any earlier batch was answered.
  def perform(feature, args, applied = 0, answered_before = false)
    return if requester.nil?

    Ai::CallContext.job(correlation_id) do
      generation = requester.ai_generation
      next finish(applied) if generation.nil?

      result = generation.call(batches: 1, cancelled: -> { requester.ai_cancelled? }, answered_before:, shadow: false)
      result.value!
      applied += requester.apply_ai(result).to_i
      # Only once applied: a deadlock in apply_ai retries the whole job, which would sample again.
      Ai::Shadow.enqueue(generation, result)

      if result.remaining.any?
        # A result has a route only when a batch was answered. An enqueue that fails returns false
        # rather than raising, and would leave the requester waiting.
        queued = self.class.perform_later(feature, args.merge(ids: result.remaining_ids), applied, answered_before || result.route.present?)
        raise ActiveJob::EnqueueError, "the next batch couldn't be queued" unless queued
      else
        finish(applied)
      end
    end
  rescue *RETRIED, *DISCARDED, ActiveRecord::Deadlocked
    raise
  rescue StandardError => error
    # Anything else (a database error while applying, a bug) ends the run here: reported, and the
    # requester told once, so a RuleRun doesn't stay pending through Sidekiq's retries.
    Rails.error.report(error, handled: true, context: { feature: arguments.first })
    give_up(error)
  end

  # retry_on doesn't check that the retry was queued, so one the queue refused, or failed to take,
  # would leave the requester waiting for good: it gives up instead.
  def retry_job(options = {})
    queued = begin
      super
    rescue StandardError => error
      Rails.error.report(error, handled: true, context: { feature: arguments.first })
      false
    end
    give_up(options[:error] || ActiveJob::EnqueueError.new("the retry couldn't be queued")) unless queued
    queued
  end

  def give_up(error)
    Rails.logger.info("[Ai::GenerationJob] #{arguments.first} gave up: #{error.class.name.demodulize} #{error.message.truncate(200)}")
    requester&.ai_failed(error)
  end

  private
    # A deadlock here is retried in place, on the same requester, which remembers what it released,
    # and gives up there when it persists. A job retry would rebuild the requester from the original
    # ids and, the batch being applied already, release those transactions a second time.
    def finish(applied, attempts: 3)
      requester.ai_finished(applied)
    rescue ActiveRecord::Deadlocked => error
      return give_up(error) if (attempts -= 1).zero?

      retry
    end

    def requester
      return @requester if defined?(@requester)

      @requester = Ai::Requesters.fetch(arguments.first).from_ai_job(**arguments.second.to_h.symbolize_keys)
    rescue ActiveRecord::RecordNotFound => error
      # The family the job names was deleted while it waited: nothing to run, and no one to tell.
      Rails.logger.info("[Ai::GenerationJob] #{arguments.first} dropped: #{error.message}")
      @requester = nil
    end

    def correlation_id
      requester.ai_correlation_id || [ arguments.second[:family_id] && "family:#{arguments.second[:family_id]}", arguments.first ].compact.join(":")
    end
end
