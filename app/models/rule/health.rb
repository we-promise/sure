# Finds a family's rules that repeat or contradict each other, or never take
# effect, for the Rule health page. Read-only: matches are queried, never acted
# on. The dry run of the active rules records claims and stops with
# Rule::Runner::Claims, as the real run does.
class Rule::Health
  # Operators that run as ILIKE, so their value's case doesn't change what
  # they match. `=` and `!=` are case-sensitive, and a pattern is compared
  # exactly as written: folding it would make `\d` and `\D` look alike.
  CASE_INSENSITIVE_OPERATORS = %w[like not_like starts_with ends_with].freeze

  # Conditions whose text a match must contain, compared for overlaps.
  TEXT_OPERATORS = %w[like = starts_with ends_with].freeze

  # The field each condition type reads that a rule's action can change.
  CONDITION_FIELDS = {
    "transaction_name" => :name,
    "transaction_merchant" => :merchant_id,
    "transaction_category" => :category_id,
    "transaction_type" => :transfer,
    "transaction_tag" => :tags
  }.freeze

  Conflict = Data.define(:rules, :attribute, :winner)
  Shadowed = Data.define(:rule, :reason, :by, :attributes, :match_count)
  Overlap = Data.define(:rule, :other, :attributes, :shared_count, :match_count, :same_text)
  # wins: the rule runs before the one being saved and sets a field it sets
  # or stops the rules below. wins and shared_count are nil when either rule
  # is switched off, since it doesn't run on sync; shared_count is nil when a
  # match query failed.
  Similar = Data.define(:rule, :position, :wins, :shared_count)

  attr_reader :rules

  def initialize(family)
    @family = family
    @rules = family.rules.ordered.includes(:actions, conditions: :sub_conditions).to_a
    Rule.share_option_lists(@rules)
  end

  # Run position, counted from 1.
  def position(rule)
    @positions ||= rules.each_with_index.to_h { |r, index| [ r.id, index + 1 ] }
    @positions[rule.id]
  end

  # Groups of rules with the same conditions, effective date, actions and
  # stop_processing.
  def duplicates
    @duplicates ||= rules.group_by { |rule| [ condition_key(rule), action_signature(rule), rule.stop_processing? ] }
      .values.select { |group| group.size > 1 }
  end

  # Rules with the same conditions that set the same field to different
  # values. The winner is the first active one: it runs first, and either
  # claims the field or stops the rules below. nil when none is active.
  def conflicts
    @conflicts ||= rules.group_by { |rule| condition_key(rule) }.values.flat_map do |group|
      next [] if group.size < 2

      setters = group.flat_map { |rule| field_values(rule).map { |attribute, value| [ attribute, rule, value ] } }
      setters.group_by(&:first).filter_map do |attribute, entries|
        next if entries.map(&:last).uniq.size < 2

        conflicting = entries.map(&:second).uniq
        Conflict.new(rules: conflicting, attribute: attribute, winner: conflicting.find(&:active?))
      end
    end
  end

  # Active rules that match transactions but change nothing: every match is
  # stopped by a rule above, or every field they set is already claimed above.
  # Matches are read before any rule runs, so a rule whose conditions read a
  # field a rule above changes gets no verdict, nor do the rules it would
  # shadow (see #dry_run).
  def shadowed
    dry_run
    @shadowed
  end

  # Active rules below another that sets the same field on transactions both
  # match, or whose conditions name the same or contained text and are
  # otherwise the same. Pairs already listed as duplicates or conflicts, and
  # shadowed rules, are left out.
  def overlaps
    @overlaps ||= begin
      skipped = shadowed.map { |entry| entry.rule.id }.to_set
      active = rules.select(&:active?).reject { |rule| failed.include?(rule) }

      active.each_with_index.flat_map do |rule, index|
        next [] if skipped.include?(rule.id)

        active.first(index).reject { |other| skipped.include?(other.id) }.filter_map { |other| overlap(rule, other) }
      end
    end
  end

  def match_nothing
    dry_run
    rules.select { |rule| rule.active? && matches_of(rule)&.empty? && !@uncertain.include?(rule.id) }
  end

  # Rules whose matches could not be read, e.g. a pattern that timed out.
  def failed
    rules.select { |rule| matches_of(rule).nil? }
  end

  def match_count(rule)
    matches_of(rule)&.size
  end

  # The family's other rules that repeat `rule`, share its conditions, or
  # name the same or contained text and set a field it sets. `rule` may be
  # unsaved, or carry unsaved changes from a form. Only those rules' matches
  # are queried, so the cost follows the few similar rules, not the family's
  # rule count.
  def similar_to(rule)
    candidate_matches = nil
    candidate_read = false

    rules.filter_map do |other|
      next if other.id == rule.id
      next unless similar?(rule, other)
      next Similar.new(rule: other, position: position(other), wins: nil, shared_count: nil) unless other.active? && runs?(rule)

      unless candidate_read
        candidate_matches = read_matches(unsaved_copy(rule))
        candidate_read = true
      end
      shared = candidate_matches && matches_of(other)&.intersection(candidate_matches)&.size
      competes = other.stop_processing? || (field_values(rule).keys & field_values(other).keys).any?
      Similar.new(rule: other, position: position(other), wins: competes && runs_before?(other, rule), shared_count: shared)
    end
  end

  private
    attr_reader :family

    def matches_of(rule)
      @matches ||= {}
      @matches.fetch(rule.id) { @matches[rule.id] = read_matches(rule) }
    end

    # A new rule is saved inactive and switched on when the user confirms it.
    def runs?(rule)
      rule.new_record? || rule.active?
    end

    # Whether `other` runs before `rule` once `rule` is saved. A new rule goes
    # last, and a rule joining or leaving a group goes right after that
    # group's other rules (Rule::Layout#place_after_group!), so there the
    # stored positions are compared with the place it will take.
    def runs_before?(other, rule)
      group = moving_group(rule)
      return position(other) < position(rule) if group.nil? && rule.persisted?
      return true if group.nil? || group.new_record?

      anchor = [ group.position.to_i, rules.select { |r| r.rule_group_id == group.id && r.id != rule.id }.map(&:position).max.to_i ].max
      other.position <= anchor
    end

    def moving_group(rule)
      # A group typed into the form is built unsaved, so rule_group_id stays as it was.
      return rule.rule_group if rule.new_record? || rule.rule_group&.new_record?
      return unless rule.rule_group_id_changed?

      rule.rule_group || family.rule_groups.find_by(id: rule.rule_group_id_was)
    end

    def similar?(rule, other)
      return true if condition_key(rule) == condition_key(other)

      (field_values(rule).keys & field_values(other).keys).any? && same_text?(rule, other)
    end

    # The rule as the form leaves it, without the conditions marked for
    # destruction, which #matching_scope would otherwise still apply.
    def unsaved_copy(rule)
      copy = Rule.new(family_id: family.id, resource_type: rule.resource_type, effective_date: rule.effective_date)
      rule.conditions.reject(&:marked_for_destruction?).each do |condition|
        copy.conditions.build(condition.slice(:condition_type, :operator, :value)).tap do |built|
          condition.sub_conditions.reject(&:marked_for_destruction?).each do |sub_condition|
            built.sub_conditions.build(sub_condition.slice(:condition_type, :operator, :value))
          end
        end
      end
      copy
    end

    # In its own savepoint, so a failing query rolls back alone and the rest
    # of the report still runs.
    def read_matches(rule)
      Rule.transaction(requires_new: true) { rule.matching_scope.pluck(:id).to_set }
    rescue => e
      Rails.logger.warn("Rule::Health could not read matches of rule #{rule.id}: #{e.class}: #{e.message}")
      nil
    end

    def dry_run
      return if @shadowed

      @shadowed = []
      @uncertain = Set.new
      changed_above = Set.new
      claims = Rule::Runner::Claims.new
      claimed_by = Hash.new { |hash, attribute| hash[attribute] = {} }
      stopped_by = {}

      rules.select(&:active?).each do |rule|
        matched = matches_of(rule)
        next if matched.nil?

        # The real run re-reads matches after the rules above apply, so a rule
        # reading a field one of them changes may match other transactions.
        @uncertain << rule.id if read_fields(rule).intersect?(changed_above)
        changed_above.merge(changed_fields(rule)) if matched.any? || @uncertain.include?(rule.id)

        unstopped = matched - claims.stopped_ids
        if matched.any? && !@uncertain.include?(rule.id) && no_effect?(rule, unstopped, claims)
          entry = shadow(rule, matched, unstopped, claims, claimed_by, stopped_by)
          involved = entry.by + matched.filter_map { |id| stopped_by[id] }
          @shadowed << entry if involved.none? { |other| @uncertain.include?(other.id) }
        end

        claims.record(rule, unstopped)
        unstopped.each { |id| stopped_by[id] ||= rule } if rule.stop_processing?
        field_values(rule).each_key { |attribute| unstopped.each { |id| claimed_by[attribute][id] ||= rule } }
      end
    end

    # As in Rule#apply: each action skips the transactions a rule above
    # claimed for any field the action sets. An action that cannot be resolved
    # fails the real run, which is not the same as changing nothing.
    def no_effect?(rule, unstopped, claims)
      rule.actions.all? do |action|
        attributes = claimed_attributes(action)
        next false if attributes.nil?

        claimed = attributes.map { |attribute| claims.claimed_ids.fetch(attribute, Set.new) }.reduce(Set.new, :|)
        (unstopped - claimed).empty?
      end
    end

    # Every rule reads :new_transactions: whatever its conditions, it can
    # match a transaction a rule above creates.
    def read_fields(rule)
      leaf_conditions(rule).filter_map { |condition| CONDITION_FIELDS[condition.condition_type] }.to_set << :new_transactions
    end

    # Tags claim nothing, but a tag condition below still reads them. A
    # transfer creates its counterpart on the target account, and a split
    # creates its children.
    def changed_fields(rule)
      rule.actions.flat_map do |action|
        case action.action_type
        when "set_transaction_tags" then [ :tags ]
        when "set_as_transfer_or_payment", "split_transaction" then claimed_attributes(action).to_a + [ :new_transactions ]
        else claimed_attributes(action).to_a
        end
      end
    end

    def shadow(rule, matched, unstopped, claims, claimed_by, stopped_by)
      if unstopped.empty?
        Shadowed.new(rule: rule, reason: :stopped, by: matched.filter_map { |id| stopped_by[id] }.uniq.sort_by { |r| position(r) },
          attributes: [], match_count: matched.size)
      else
        attributes = rule.actions.flat_map { |action| claimed_attributes(action).to_a }.uniq
        by = attributes.flat_map { |attribute| unstopped.filter_map { |id| claimed_by[attribute][id] } }.uniq
        Shadowed.new(rule: rule, reason: :claimed, by: by.sort_by { |r| position(r) }, attributes: attributes,
          match_count: unstopped.size)
      end
    end

    def overlap(rule, other)
      return if listed_together?(rule, other)

      attributes = field_values(rule).keys & field_values(other).keys
      return if attributes.empty?

      shared = matches_of(rule) & matches_of(other)
      same_text = same_text?(rule, other)
      return if shared.empty? && !same_text

      Overlap.new(rule: rule, other: other, attributes: attributes, shared_count: shared.size,
        match_count: matches_of(rule).size, same_text: same_text)
    end

    def listed_together?(rule, other)
      (duplicates + conflicts.map(&:rules)).any? { |group| group.include?(rule) && group.include?(other) }
    end

    # Only when nothing else separates them: their other conditions are the
    # same, they don't require different merchants, and the names they
    # require can all hold at once.
    def same_text?(rule, other)
      return false unless conditions_besides_text(rule) == conditions_besides_text(other)

      merchant_ids, other_merchant_ids = merchant_ids(rule), merchant_ids(other)
      return false if merchant_ids.any? && other_merchant_ids.any? && merchant_ids != other_merchant_ids
      return false if contradicting_names?(rule, other)

      texts(rule).any? { |text| texts(other).any? { |other_text| same_or_contained?(text, other_text) } }
    end

    # `=` is exact and compares case, so its text only overlaps a condition it
    # would itself match. A merchant `=` compares the merchant, not its name.
    def same_or_contained?((text, operator, merchant_id), (other_text, other_operator, other_merchant_id))
      return merchant_id == other_merchant_id if merchant_id && other_merchant_id
      return text == other_text if operator == "=" && other_operator == "="
      return matches_text?(text, other_text, other_operator) if operator == "="
      return matches_text?(other_text, text, operator) if other_operator == "="

      text, other_text = text.downcase, other_text.downcase
      if operator == "starts_with" && other_operator == "starts_with"
        text.start_with?(other_text) || other_text.start_with?(text)
      elsif operator == "ends_with" && other_operator == "ends_with"
        text.end_with?(other_text) || other_text.end_with?(text)
      else
        text.include?(other_text) || other_text.include?(text)
      end
    end

    # Two different exact names, or two prefixes (or suffixes) neither of
    # which extends the other.
    def contradicting_names?(rule, other)
      names = ->(r) { required_conditions(r).select { |condition| condition.condition_type == "transaction_name" } }
      names.(rule).product(names.(other)).any? do |condition, other_condition|
        next false unless condition.operator == other_condition.operator

        text, other_text = [ condition, other_condition ].map { |c| c.value.to_s.gsub(/\s+/, " ").strip }
        case condition.operator
        when "=" then text != other_text
        when "starts_with" then !text.downcase.start_with?(other_text.downcase) && !other_text.downcase.start_with?(text.downcase)
        when "ends_with" then !text.downcase.end_with?(other_text.downcase) && !other_text.downcase.end_with?(text.downcase)
        else false
        end
      end
    end

    # Conditions every match meets: those at the top level and in AND groups.
    def required_conditions(rule)
      rule.conditions.flat_map do |condition|
        next [ condition ] unless condition.compound?

        condition.operator == "and" ? condition.sub_conditions.to_a : []
      end
    end

    def merchant_ids(rule)
      required_conditions(rule).select { |condition| condition.condition_type == "transaction_merchant" && condition.operator == "=" }
        .map { |condition| condition.value.to_s }.to_set
    end

    # Whether an exact value passes a contains, starts with or ends with
    # condition, which all ignore case.
    def matches_text?(value, text, operator)
      value, text = value.downcase, text.downcase
      case operator
      when "starts_with" then value.start_with?(text)
      when "ends_with" then value.end_with?(text)
      else value.include?(text)
      end
    end

    # The text a match must contain, with a merchant condition read as its
    # merchant's name, its operator, and the merchant's id for a merchant
    # condition.
    def texts(rule)
      @texts ||= {}.compare_by_identity
      @texts[rule] ||= leaf_conditions(rule).filter_map do |condition|
        next unless TEXT_OPERATORS.include?(condition.operator)

        text = case condition.condition_type
        when "transaction_name" then condition.value
        when "transaction_merchant" then merchant_name(condition.value.to_s)
        end
        text = text.to_s.gsub(/\s+/, " ").strip.presence
        [ text, condition.operator, (condition.value.to_s if condition.condition_type == "transaction_merchant") ] if text
      end
    end

    # The conditions other than the compared text, with groups flattened.
    def conditions_besides_text(rule)
      condition_signature(leaf_conditions(rule).reject do |condition|
        %w[transaction_name transaction_merchant].include?(condition.condition_type) && TEXT_OPERATORS.include?(condition.operator)
      end)
    end

    def merchant_names
      @merchant_names ||= begin
        ids = rules.flat_map { |rule| leaf_conditions(rule) }
          .select { |condition| condition.condition_type == "transaction_merchant" }.map(&:value).compact_blank.uniq
        Merchant.where(id: ids.select { |id| UuidFormat.valid?(id) }).pluck(:id, :name).to_h { |id, name| [ id.to_s, name ] }
      end
    end

    # A rule being saved can name a merchant none of the family's rules do.
    def merchant_name(id)
      merchant_names.fetch(id) { merchant_names[id] = (Merchant.where(id: id).pick(:name) if UuidFormat.valid?(id)) }
    end

    # The fields a rule claims, with the value it sets each to.
    def field_values(rule)
      @field_values ||= {}.compare_by_identity
      @field_values[rule] ||= rule.actions.each_with_object({}) do |action, values|
        next if action.marked_for_destruction? || !reserves_claims?(action)

        claimed_attributes(action).to_a.each { |attribute| values[attribute] = action.value.to_s }
      end
    end

    # nil when the action cannot be resolved (e.g. an unknown type from an
    # import): it changes nothing.
    def claimed_attributes(action)
      action.claimed_attributes
    rescue Rule::Registry::UnsupportedActionError
      nil
    end

    def reserves_claims?(action)
      action.reserves_claimed_attributes?
    rescue Rule::Registry::UnsupportedActionError
      false
    end

    def condition_key(rule)
      [ rule.effective_date, condition_signature(rule.conditions) ]
    end

    # Order doesn't count, and an AND group reads like its conditions listed
    # at the top level.
    def condition_signature(conditions)
      conditions.reject(&:marked_for_destruction?)
        .flat_map { |condition| condition.compound? && condition.operator == "and" ? condition.sub_conditions.reject(&:marked_for_destruction?) : [ condition ] }
        .map do |condition|
          if condition.compound?
            [ "compound", condition.operator.to_s, condition_signature(condition.sub_conditions) ]
          else
            [ condition.condition_type.to_s, condition.operator.to_s, condition_value(condition) ]
          end
        end
        .sort_by(&:inspect)
    end

    # Normalised the way each filter matches it. A pattern is compared as
    # written. The JSON detail filters bind their value without collapsing
    # whitespace: an additional detail strips only the ends of its key and
    # value, and transaction details binds the value as typed. Other text has
    # its whitespace collapsed.
    def condition_value(condition)
      return "" if Rule::ConditionFilter::VALUELESS_OPERATORS.include?(condition.operator)

      value = condition.value.to_s
      return value if condition.regex?

      case condition.condition_type
      when "transaction_additional_detail"
        # The key before the first "=" is looked up exactly.
        key, separator, target = value.partition(Rule::ConditionFilter::TransactionAdditionalDetail::KEY_VALUE_SEPARATOR)
        [ key.strip, separator, fold_case(condition, target.strip) ].join
      when "transaction_details"
        fold_case(condition, value)
      else
        value = value.gsub(/\s+/, " ").strip if condition.filter.type == "text"
        fold_case(condition, value)
      end
    end

    def fold_case(condition, value)
      CASE_INSENSITIVE_OPERATORS.include?(condition.operator) ? value.downcase : value
    end

    def action_signature(rule)
      rule.actions.reject(&:marked_for_destruction?).map { |action| [ action.action_type.to_s, action.value.to_s ] }.sort
    end

    def leaf_conditions(rule)
      rule.conditions.reject(&:marked_for_destruction?)
        .flat_map { |condition| condition.compound? ? condition.sub_conditions.reject(&:marked_for_destruction?) : [ condition ] }
    end
end
