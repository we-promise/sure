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

  # Runs a rule's actions (the block) with their AI jobs queued after the last
  # one, so no job can finish the run before every AI action has counted its
  # own. Jobs counted before an action raised are still queued.
  def self.queue_ai_jobs_after
    jobs = []
    previous = ActiveSupport::IsolatedExecutionState[DEFERRED_AI_JOBS]
    ActiveSupport::IsolatedExecutionState[DEFERRED_AI_JOBS] = jobs
    yield
  ensure
    ActiveSupport::IsolatedExecutionState[DEFERRED_AI_JOBS] = previous
    jobs.each(&:call)
  end

  protected
    # Queues one AI job per batch of `scope`, each counted on the run before
    # any is queued, so a job that finishes at once finds itself counted. The
    # block queues a batch and returns whether it was queued; a batch that
    # wasn't counts as a failed job. Inside queue_ai_jobs_after, the jobs are
    # queued once every action has run; otherwise at once.
    def queue_ai_jobs(scope, rule_run:, &queue)
      batches = scope.pluck(:id).each_slice(Provider::LlmConcept.max_items_per_call).to_a
      rule_run&.await_jobs!(batches.size)

      jobs = batches.map { |ids| -> { queue_ai_job(scope.model.where(id: ids), ids, rule_run:, &queue) } }
      deferred = ActiveSupport::IsolatedExecutionState[DEFERRED_AI_JOBS]
      deferred ? deferred.concat(jobs) : jobs.each(&:call)
    end

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
    attr_reader :rule

    # Never raises, so one batch can't keep the others from being queued.
    def queue_ai_job(batch, ids, rule_run:)
      raise ActiveJob::EnqueueError, "the AI job couldn't be queued" unless yield(batch)
    rescue StandardError => error
      Rails.logger.error("[#{self.class.name}] #{error.class}: #{error.message}")
      fail_unqueued_job(rule_run, error, ids)
    end

    def fail_unqueued_job(rule_run, error, ids)
      rule_run&.fail_job!(job_id: SecureRandom.uuid, error:, source: self.class.name, transaction_ids: ids)
    rescue StandardError => settle_error
      Rails.error.report(settle_error, handled: true, context: { rule_run_id: rule_run.id, source: self.class.name })
    end

    def family
      rule.family
    end
end
