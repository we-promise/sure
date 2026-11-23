# Base for the AI jobs a rule run queues, one per batch of transactions.
#
# A failure a later attempt can get past (a timeout, a 429, a 5xx, an
# unreachable server, a deadlock, a lost database connection) is retried a few
# times. Anything else (a rejected key, any other 4xx, no provider or
# categories, a response that doesn't parse) fails the same way on every
# attempt, so the batch ends there. Either way the run hears once, when the job
# is done for good. A retry sends only what the earlier attempt left: applied
# transactions are locked, and the enrichers skip locked ones.
class RuleAiJob < ApplicationJob
  queue_as :ai_low_priority
  # The budget below handles every failure perform raises. Sidekiq's few
  # retries only catch what escapes it: the run's row failing to settle when
  # the job gives up, or a retry that can't be queued. They reuse the job_id,
  # so the run still counts the job once.
  sidekiq_options retry: 3

  ATTEMPTS = 5
  RETRIED = [ Ai::Error::RateLimited, Ai::Error::Timeout, Ai::Error::Upstream, Ai::Error::Unreachable ].freeze
  TRANSIENT_DB = [ ActiveRecord::Deadlocked, ActiveRecord::ConnectionNotEstablished, ActiveRecord::ConnectionFailed ].freeze
  DISCARDED = [ Ai::Error::Unauthorized, Ai::Error::NoCredit, Ai::Error::ModelMissing, Ai::Error::ContextTooLong,
                Ai::Error::InvalidOutput, Ai::Error::Refused, Ai::Error::Cancelled ].freeze

  retry_on(*RETRIED, wait: :polynomially_longer, attempts: ATTEMPTS) { |job, error| job.give_up(error) }
  retry_on(*TRANSIENT_DB, attempts: ATTEMPTS) { |job, error| job.give_up(error) }
  discard_on(*DISCARDED) { |job, error| job.give_up(error) }

  def perform(family, transaction_ids: [], rule_run_id: nil, user_id: nil)
    @transaction_ids = transaction_ids
    @rule_run = RuleRun.find_by(id: rule_run_id) if rule_run_id.present?

    # Access may have changed since the rule queued the batch (Rule::AiEnrichment).
    user = family.users.find_by(id: user_id)
    modified_count = enrich(family, Rule::AiEnrichment.permitted_ids(family, transaction_ids, user:))
    @rule_run&.complete_job!(job_id:, modified_count:)
  rescue *TRANSIENT_DB
    raise
  rescue StandardError => error
    ai_error = ai_error_for(error)
    raise ai_error if ai_error

    # Reported once here, where Sidekiq's retries used to report it each time.
    Rails.error.report(error, handled: true, context: { job: self.class.name, rule_run_id: })
    give_up(error)
  end

  def give_up(error)
    Rails.logger.info("[#{self.class.name}] gave up: #{error.class.name} #{error.message.truncate(200)}")
    @rule_run&.fail_job!(job_id:, error:, source: self.class.name, transaction_ids: @transaction_ids)
  end

  private
    # @return [Integer] how many transactions the batch changed
    def enrich(family, transaction_ids)
      raise NotImplementedError
    end

    # The enrichers wrap the provider's error, which wraps the client's.
    def ai_error_for(error)
      while error
        mapped = Ai::Error.from_exception(error)
        return mapped if mapped

        error = error.cause
      end
    end
end
