class Rule::ActionExecutor
  TYPES = [ "select", "multi_select", "function", "text" ]

  def initialize(rule)
    @rule = rule
  end

  def key
    self.class.name.demodulize.underscore
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
    attr_reader :rule

    def family
      rule.family
    end
end
