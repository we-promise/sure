# Sets a transaction's name from one of the provider fields shown under
# "Additional details" (transactions.extra), so a provider quirk can be resolved
# with a rule instead of a branch in the provider processor.
#
# The motivating case: an ASPSP leaves the counterparty name blank and puts the
# merchant descriptor in the counterparty's postal address. EnableBankingEntry::
# Processor exposes that address as extra["enable_banking"]["counterparty_address"],
# and one rule -- condition "Additional details counterparty_address is present",
# action "Set transaction name from additional details: counterparty_address" --
# then names every such transaction after its merchant.
#
# The value is the field key, resolved at any depth like
# Rule::ConditionFilter::TransactionAdditionalDetail, so the rule does not need
# to know the provider namespace the field sits under. Only string values are
# used; a number or a nested object names nothing.
class Rule::ActionExecutor::SetTransactionNameFromAdditionalDetail < Rule::ActionExecutor
  def label
    "Set transaction name from additional details"
  end

  def type
    "text"
  end

  def options
    nil
  end

  # Shown after the label in the rule list, so the copied field is visible.
  def value_display(value)
    value.presence
  end

  def claimed_attributes
    [ :name ]
  end

  # Only rows that actually carry the field get a name, so this must not reserve
  # :name for every transaction the rule matched -- a broad rule would otherwise
  # silently block lower rules from naming rows this action left alone.
  def reserves_claimed_attributes?
    false
  end

  def actionable?(value)
    value.present?
  end

  def execute(transaction_scope, value: nil, ignore_attribute_locks: false, rule_run: nil)
    key = value.to_s.strip
    return 0 if key.blank?

    scope = transaction_scope.with_entry
    unless ignore_attribute_locks
      # Filter by the entry's locked_attributes, not the transaction's: name is
      # on the entry (mirrors Rule::ActionExecutor::SetTransactionName).
      scope = scope.where.not(Arel.sql("entries.locked_attributes ? 'name'"))
    end

    count_modified_resources(scope) do |txn|
      name = additional_detail_value(txn.extra, key)
      next false if name.blank?

      txn.entry.enrich_attribute(
        :name,
        name.truncate(100),
        source: "rule",
        ignore_locks: ignore_attribute_locks
      )
    end
  end

  private
    # First string value stored under +key+ at any depth in the document.
    # Every key at the current level is checked before descending, so a shallower
    # match wins over a deeper one regardless of key order.
    def additional_detail_value(node, key)
      case node
      when Hash
        node.each do |candidate_key, value|
          return value if candidate_key.to_s == key && value.is_a?(String)
        end

        node.each_value do |value|
          found = additional_detail_value(value, key)
          return found if found
        end
        nil
      when Array
        node.each do |value|
          found = additional_detail_value(value, key)
          return found if found
        end
        nil
      end
    end
end
