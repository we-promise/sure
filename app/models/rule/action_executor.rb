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

  # Whether the action hands its work to background jobs (the AI actions).
  # Rule#apply runs those last, so the jobs can leave out the transactions the
  # other actions changed when they report their own changes. Such an executor
  # appends its enqueue calls to async_jobs when given one, so the runner can
  # record the pending count before any job runs.
  def async?
    false
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

  def execute(scope, value: nil, ignore_attribute_locks: false, rule_run: nil, modified_transaction_ids: nil, already_modified_count: 0, async_jobs: nil)
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

  protected
    # Helper method to track modified count during enrichment.
    # The block should return true if the resource was modified, false otherwise.
    # If the block doesn't return a value, we'll check previous_changes as a fallback.
    # modified_transaction_ids collects the ids, so Rule#apply can count a
    # transaction once even when several actions change it.
    def count_modified_resources(scope, modified_transaction_ids: nil)
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

        if was_modified
          modified_count += 1
          modified_transaction_ids&.add(resource.id)
        end
      end
      modified_count
    end

  private
    attr_reader :rule

    def family
      rule.family
    end
end
