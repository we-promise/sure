class Rule::ActionExecutor
  TYPES = [ "select", "multi_select", "function", "text", "split" ]

  def initialize(rule)
    @rule = rule
  end

  def self.key
    name.demodulize.underscore
  end

  def key
    self.class.key
  end

  def label
    key.humanize
  end

  def type
    "function"
  end

  def options
    nil
  end

  # The option for a saved value that options leaves out (e.g. a merchant only
  # on accounts the current user can't see, or one no longer assigned), so
  # editing the rule keeps the value instead of silently switching to the
  # first option. nil if the value doesn't refer to a record at all.
  def option_for(value)
    nil
  end

  # Attributes this action sets. When several rules set the same attribute on
  # a transaction, the rule highest in the list wins (see Rule::Runner), so the
  # action skips transactions a rule above already claimed. Additive actions
  # such as tags claim nothing.
  def claimed_attributes
    []
  end

  # Whether matching this action keeps rules further down from setting
  # claimed_attributes. False for actions that only fill a field later and not
  # for every match, so a broad one doesn't silently block the rules below it.
  def reserves_claimed_attributes?
    true
  end

  # Whether this action can change anything with the given value. An action
  # that cannot (e.g. its category was deleted) claims nothing, so it doesn't
  # keep the rules below it from setting the field.
  def actionable?(value)
    true
  end

  def execute(scope, value: nil, ignore_attribute_locks: false, rule_run: nil)
    raise NotImplementedError, "Action executor #{self.class.name} must implement #execute"
  end

  def as_json
    {
      type: type,
      key: key,
      label: label,
      options: options
    }
  end

  # Executors with a non-trivial value format (e.g. structured JSON) can override this
  # to provide a human-readable summary for the rule list view. Returning nil falls back
  # to the default (options-based) display logic in Rule::Action#value_display.
  def value_display(value)
    nil
  end

  DEFERRED_AI_JOBS = :rule_action_executor_deferred_ai_jobs

  # A counted AI job, queued later. queue! queues it, or gives its count back and raises; release!
  # gives the count back without queuing. A failure while giving it back is logged, so it doesn't
  # replace the error that stopped the job being queued.
  AiJob = Struct.new(:name, :rule_run, :count, :queue, keyword_init: true) do
    def queue!
      queued = begin
        queue.call
      rescue StandardError
        release!
        raise
      end
      return if queued

      release!
      raise ActiveJob::EnqueueError, "the AI job couldn't be queued"
    end

    def release!
      rule_run&.release_ai_job!(count)
    rescue StandardError => error
      Rails.logger.error("[#{name}] couldn't release #{count} awaited transactions: #{error.class}: #{error.message}")
    end
  end

  # Runs the block, a rule's actions, with each AI action's job counted at once and queued after
  # them all, so no job can finish the run before the rule's last AI action has counted its own.
  # When an action raises, the jobs the actions before it counted are still queued, as they were
  # when each queued its own, and the error is raised. A job that can't be queued gives its count
  # back, as do the ones after it, which are never queued.
  def self.queue_ai_jobs_after
    jobs = []
    previous = ActiveSupport::IsolatedExecutionState[DEFERRED_AI_JOBS]
    ActiveSupport::IsolatedExecutionState[DEFERRED_AI_JOBS] = jobs
    result = begin
      yield
    rescue StandardError
      ActiveSupport::IsolatedExecutionState[DEFERRED_AI_JOBS] = previous
      queue_all(jobs, raise_errors: false)
      raise
    end
    ActiveSupport::IsolatedExecutionState[DEFERRED_AI_JOBS] = previous
    queue_all(jobs)
    result
  end

  def self.queue_all(jobs, raise_errors: true)
    jobs.each_with_index do |job, index|
      job.queue!
    rescue StandardError => error
      jobs.drop(index + 1).each(&:release!)
      raise if raise_errors

      Rails.logger.error("[Rule::ActionExecutor] couldn't queue an AI job after a failed action: #{error.class}: #{error.message}")
      break
    end
  end
  private_class_method :queue_all

  protected
    # Helper method to track modified count during enrichment
    # The block should return true if the resource was modified, false otherwise
    # If the block doesn't return a value, we'll check previous_changes as a fallback
    def count_modified_resources(scope)
      modified_count = 0
      scope.each do |resource|
        # Yield the resource and capture the return value if the block returns one
        block_result = yield resource

        # If the block explicitly returned a boolean, use that
        if block_result == true || block_result == false
          was_modified = block_result
        else
          # Otherwise, check previous_changes as fallback
          was_modified = resource.previous_changes.any?

          # For Transaction resources, check the entry if the transaction itself wasn't modified
          if !was_modified && resource.respond_to?(:entry)
            entry = resource.entry
            was_modified = entry&.previous_changes&.any? || false
          end
        end

        modified_count += 1 if was_modified
      end
      modified_count
    end

  private
    # For an AI action: one Ai::GenerationJob for every transaction in `scope`, which sends one batch
    # sized for the model and queues the rest behind other families' work. The run counts the job
    # and awaits the transactions now, and the job counts them down and hears back once
    # (RuleRun#complete_job!). The block queues the job and returns whether it was queued; when it
    # wasn't, or raised, the run stops waiting for both and the error is raised. Inside
    # Rule::ActionExecutor.queue_ai_jobs_after, the job is queued once every action has run.
    def enqueue_ai_job(scope, rule_run:, &queue)
      transactions = scope.select(:id).to_a   # one read, so the count matches what's queued
      count = transactions.size
      Rails.logger.info("Scheduling #{key} for #{count} transactions")
      rule_run&.await_ai!(count)

      job = AiJob.new(name: self.class.name, rule_run:, count:, queue: -> { queue.call(transactions) })
      deferred = ActiveSupport::IsolatedExecutionState[DEFERRED_AI_JOBS]
      deferred ? deferred << job : job.queue!

      { async: true, modified_count: count }
    end

    attr_reader :rule

    def family
      rule.family
    end
end
