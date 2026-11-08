# The one job every generation feature runs in. It runs one batch, applies it through the
# requester and enqueues the rest at the back of its queue, so one family's large run takes turns
# with other families' work. The queue comes from the feature's lane (Ai::Routes.queue_for).
#
# On a failure, the transport has already retried 429s and 5xxs and the generation
# has failed over and escalated; what's left is retried later when it may pass, and discarded
# when it can't. Either way the requester hears once, so a RuleRun never stays pending.
class Ai::GenerationJob < ApplicationJob
  queue_as { Ai::Routes.queue_for(arguments.first) }

  RETRIED = [ Ai::Error::RateLimited, Ai::Error::Timeout, Ai::Error::Upstream, Ai::Error::Unreachable ].freeze
  DISCARDED = [ Ai::Error::Unavailable, Ai::Error::Refused, Ai::Error::Unauthorized, Ai::Error::NoCredit,
                Ai::Error::ModelMissing, Ai::Error::ContextTooLong, Ai::Error::InvalidOutput, Ai::Error::Cancelled ].freeze

  retry_on(*RETRIED, wait: :polynomially_longer, attempts: 5) { |job, error| job.give_up(error) }
  discard_on(*DISCARDED) { |job, error| job.give_up(error) }

  # feature: a key in Ai::Requesters; args: the requester's own (`ids:` the items left); applied:
  # the count the earlier batches applied.
  def perform(feature, args, applied = 0)
    Ai::CallContext.job(correlation_id) do
      generation = requester.ai_generation
      next requester.ai_finished(applied) if generation.nil?

      result = generation.call(batches: 1, cancelled: -> { requester.ai_cancelled? })
      result.value!
      applied += requester.apply_ai(result).to_i

      if result.remaining.any?
        self.class.perform_later(feature, args.merge(ids: result.remaining_ids), applied)
      else
        requester.ai_finished(applied)
      end
    end
  end

  def give_up(error)
    Rails.logger.info("[Ai::GenerationJob] #{arguments.first} gave up: #{error.class.name.demodulize} #{error.message.truncate(200)}")
    requester.ai_failed(error)
  end

  private
    def requester
      @requester ||= Ai::Requesters.fetch(arguments.first).from_ai_job(**arguments.second.to_h.symbolize_keys)
    end

    def correlation_id
      requester.ai_correlation_id || [ arguments.second[:family_id] && "family:#{arguments.second[:family_id]}", arguments.first ].compact.join(":")
    end
end
