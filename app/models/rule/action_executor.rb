class Rule::ActionExecutor
  TYPES = [ "select", "function", "text" ]

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

  def execute(scope, value: nil, ignore_attribute_locks: false)
    raise NotImplementedError, "Action executor #{self.class.name} must implement #execute"
  end

  protected
    # Helper method to track modified count during enrichment
    def count_modified_resources(scope)
      modified_count = 0
      scope.each do |resource|
        yield resource
        # Check if the resource was actually modified (has changes)
        modified_count += 1 if resource.previous_changes.any?
      end
      modified_count
    end

  def as_json
    {
      type: type,
      key: key,
      label: label,
      options: options
    }
  end

  private
    attr_reader :rule

    def family
      rule.family
    end
end
