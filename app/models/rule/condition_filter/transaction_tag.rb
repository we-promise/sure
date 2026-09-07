class Rule::ConditionFilter::TransactionTag < Rule::ConditionFilter
  def type
    "select"
  end

  def options
    family.tags.alphabetically.pluck(:name, :id)
  end

  # Tag membership is matched with a correlated EXISTS subquery rather than a
  # join. A join on a has_many association would (a) let two ANDed tag conditions
  # collapse onto the same `tags.id` alias — `tags.id = a AND tags.id = b` can
  # never be true even when the transaction has both tags — and (b) return a
  # transaction once per matching tagging row, inflating counts and making rule
  # actions iterate duplicates. EXISTS keeps each condition independent and never
  # multiplies rows, so no join (or DISTINCT) is needed here.
  def prepare(scope)
    scope
  end

  def apply(scope, operator, value)
    case operator
    when "="
      scope.where(tagging_exists(tag_id: value))
    when "is_null"
      scope.where(Arel::Nodes::Not.new(tagging_exists))
    else
      raise UnsupportedOperatorError, "Unsupported operator: #{operator} for type: #{type}"
    end
  end

  private
    # Builds an Arel EXISTS node correlating taggings to the outer transactions
    # row. When +tag_id+ is given it matches that specific tag; otherwise it
    # matches any tag (negated for the "is_null" / has-no-tags operator).
    def tagging_exists(tag_id: nil)
      taggings = Tagging
        .where(Tagging.arel_table[:taggable_id].eq(Transaction.arel_table[:id]))
        .where(taggable_type: "Transaction")
      taggings = taggings.where(tag_id: tag_id) if tag_id.present?
      taggings.arel.exists
    end
end
