# The one job every generation feature runs in. It runs one batch, applies it through the
# requester and enqueues the rest at the back of its queue, so one family's large run takes turns
# with other families' work. The queue comes from the feature's lane (Ai::Routes.queue_for).
#
# The run's ids live in an Ai::GenerationRun (Ai::GenerationRun.enqueue starts one); each job reads
# one window of them, so a job's work and payload stay at about one batch however long the run is.
#
# Each job is one step of the run. It claims its step in the transaction that applies its batch,
# which also saves the next job's arguments or, on the last step, ends the run. A replayed job
# whose step already committed queues that next job rather than reporting the batch again, and a
# second copy of a job stops at the claim, so the requester hears each batch, and the end, once.
#
# On a failure, the transport has already retried 429s and 5xxs and the generation
# has failed over and escalated; what's left is retried later when it may pass, and discarded
# when it can't. Any other error ends the run. Either way the requester hears once, so a RuleRun
# never stays pending.
class Ai::GenerationJob < ApplicationJob
  queue_as { Ai::Routes.queue_for(arguments.first) }

  # Another copy of this job committed its step first; that copy carries the run on.
  StepTaken = Class.new(StandardError)

  RETRIED = [ Ai::Error::RateLimited, Ai::Error::Timeout, Ai::Error::Upstream, Ai::Error::Unreachable ].freeze
  DISCARDED = [ Ai::Error::Unavailable, Ai::Error::Refused, Ai::Error::Unauthorized, Ai::Error::NoCredit,
                Ai::Error::ModelMissing, Ai::Error::ContextTooLong, Ai::Error::InvalidOutput, Ai::Error::Cancelled ].freeze

  retry_on(*RETRIED, wait: :polynomially_longer, attempts: 5) { |job, error| job.give_up(error) }
  retry_on(ActiveRecord::Deadlocked, attempts: 5) { |job, error| job.give_up(error) }
  discard_on(*DISCARDED) { |job, error| job.give_up(error) }

  # feature: a key in Ai::Requesters; args: `run_id:`, `cursor:` (the run's next unread position),
  # `pending:` (the ids the last batch left unanswered) and `step:` (this job's step of the run),
  # plus the requester's own; applied: the count the earlier batches applied; answered_before:
  # whether any earlier batch was answered.
  def perform(feature, args, applied = 0, answered_before = false)
    return if requester.nil?
    return resume if @window.run.step > @step

    runs.where(step: @step).update_all(next_job: nil)   # started: a replay of the step before won't queue this one again
    Ai::CallContext.job(correlation_id) do
      generation = requester.ai_generation
      next commit_step(last: true) { finish(applied) } if generation.nil?

      result = generation.call(batches: 1, cancelled: -> { requester.ai_cancelled? }, answered_before:, shadow: false)
      result.value!
      last = result.remaining.none? && @window.exhausted?
      next_job = commit_step(last:) do
        applied += requester.apply_ai(result).to_i
        next finish(applied) if last

        # A result has a route only when a batch was answered.
        { args: args.to_h.symbolize_keys.merge(cursor: @window.cursor, pending: result.remaining_ids, step: @step + 1),
          applied:, answered_before: answered_before || result.route.present? }
      end
      # Only once committed: a deadlock in the step retries the whole job, which would sample again.
      Ai::Shadow.enqueue(generation, result)
      enqueue_next if !last && become(next_job)
    end
  rescue StepTaken
    Rails.logger.info("[Ai::GenerationJob] #{feature} step #{@step} was committed by another copy; stopping")
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

  # Ends the run, in one transaction with the requester hearing it, so a deadlock leaves both
  # undone. Only from the run's latest step: a copy that fell behind ends nothing.
  def give_up(error)
    Rails.logger.info("[Ai::GenerationJob] #{arguments.first} gave up: #{error.class.name.demodulize} #{error.message.truncate(200)}")
    return if requester.nil?

    ActiveRecord::Base.transaction { end_run { requester.ai_failed(error) } }
  end

  private
    # One transaction claims this step, runs the block (the batch's apply) and saves the next job
    # the block returns or, on the last step, ends the run. Returns the block's value.
    def commit_step(last:)
      ActiveRecord::Base.transaction do
        if last
          raise StepTaken unless end_run { yield }
        else
          raise StepTaken unless runs.where(step: @step).update_all(step: @step + 1, updated_at: Time.current).positive?

          yield.tap { |next_job| runs.update_all(next_job:) }
        end
      end
    end

    # If the run is still at this job's step: locks it, so no other copy can end it, runs the
    # block (the requester hearing the end, which may read the window's items) and deletes the run
    # with its items. Returns whether it ended the run.
    def end_run
      return false unless runs.lock.find_by(step: @step)

      yield
      runs.delete_all
      true
    end

    def runs = Ai::GenerationRun.where(id: @window.run.id)

    # This job's step committed already: it's a replay, or a second copy. When the step is the
    # run's latest, the job that committed it may have ended before queuing the next, so that one
    # is queued from what the step saved; if it was queued already, one of the two stops at its claim.
    def resume
      run = @window.run
      return unless run.step == @step + 1 && run.next_job

      enqueue_next if become(run.next_job.deep_symbolize_keys)
    end

    # From here the job stands for the step it queues, so giving up releases that step's window
    # and the ids after it, not this step's, which committed. Returns the new requester.
    def become(next_job)
      self.arguments = [ arguments.first, next_job[:args], next_job[:applied], next_job[:answered_before] ]
      remove_instance_variable(:@requester)
      requester
    end

    # An enqueue that fails returns false rather than raising, and would leave the requester waiting.
    def enqueue_next
      raise ActiveJob::EnqueueError, "the next batch couldn't be queued" unless self.class.perform_later(*arguments)
    end

    # Inside commit_step, which has ended the run.
    def finish(applied)
      requester.ai_finished(applied)
      nil
    end

    def requester
      return @requester if defined?(@requester)

      klass = Ai::Requesters.fetch(arguments.first)
      args = arguments.second.to_h.symbolize_keys
      run = Ai::GenerationRun.find_by!(id: args.delete(:run_id), family_id: args[:family_id])
      run.touch   # progress, which the sweep goes by
      @step = args.delete(:step).to_i
      @window = run.window(cursor: args.delete(:cursor), pending: args.delete(:pending),
                           size: Ai::Config.current.window_for(arguments.first))
      @requester = klass.from_ai_job(window: @window, **args)
    rescue ActiveRecord::RecordNotFound => error
      # The family the job names was deleted while it waited, or the run already ended (finished,
      # given up, swept): nothing to run, and no one to tell.
      Rails.logger.info("[Ai::GenerationJob] #{arguments.first} dropped: #{error.message}")
      @requester = nil
    rescue KeyError
      # A stale job for a feature no longer registered: give up once, don't poison the queue.
      Rails.logger.error("[Ai::GenerationJob] no requester registered for #{arguments.first.inspect}; dropping")
      @requester = nil
    end

    def correlation_id
      fallback = [ arguments.second[:family_id] && "family:#{arguments.second[:family_id]}", arguments.first ].compact.join(":")
      return fallback unless requester

      requester.ai_correlation_id || fallback
    end
end
