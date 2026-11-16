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

  Conflict = Data.define(:rules, :attribute, :winner)
  Shadowed = Data.define(:rule, :reason, :by, :attributes, :match_count)
  Overlap = Data.define(:rule, :other, :attributes, :shared_count, :match_count, :same_text)

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

  # Groups of rules with the same conditions, effective date and actions.
  def duplicates
    @duplicates ||= rules.group_by { |rule| [ condition_key(rule), action_signature(rule) ] }
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
  def shadowed
    dry_run
    @shadowed
  end

  # Active rules below another that sets the same field on transactions both
  # match, or whose conditions name the same or contained text. Pairs already
  # listed as duplicates or conflicts, and shadowed rules, are left out.
  def overlaps
    @overlaps ||= begin
      skipped = shadowed.map { |entry| entry.rule.id }.to_set
      active = rules.select(&:active?).reject { |rule| failed.include?(rule) }

      active.each_with_index.flat_map do |rule, index|
        next [] if skipped.include?(rule.id)

        active.first(index).filter_map { |other| overlap(rule, other) }
      end
    end
  end

  def match_nothing
    rules.select { |rule| matches[rule.id]&.empty? }
  end

  # Rules whose matches could not be read, e.g. a pattern that timed out.
  def failed
    rules.select { |rule| matches[rule.id].nil? }
  end

  def match_count(rule)
    matches[rule.id]&.size
  end

  private
    attr_reader :family

    def matches
      @matches ||= rules.to_h { |rule| [ rule.id, read_matches(rule) ] }
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
      claims = Rule::Runner::Claims.new
      claimed_by = Hash.new { |hash, attribute| hash[attribute] = {} }
      stopped_by = {}

      rules.select(&:active?).each do |rule|
        matched = matches[rule.id]
        next if matched.nil?

        unstopped = matched - claims.stopped_ids
        @shadowed << shadow(rule, matched, unstopped, claims, claimed_by, stopped_by) if matched.any? && no_effect?(rule, unstopped, claims)

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

    def shadow(rule, matched, unstopped, claims, claimed_by, stopped_by)
      if unstopped.empty?
        Shadowed.new(rule: rule, reason: :stopped, by: matched.filter_map { |id| stopped_by[id] }.uniq.sort_by { |r| position(r) },
          attributes: [], match_count: matched.size)
      else
        attributes = rule.actions.flat_map { |action| claimed_attributes(action).to_a }.uniq
        by = attributes.flat_map { |attribute| unstopped.filter_map { |id| claimed_by[attribute][id] } }.uniq
        Shadowed.new(rule: rule, reason: :claimed, by: by.sort_by { |r| position(r) }, attributes: attributes,
          match_count: matched.size)
      end
    end

    def overlap(rule, other)
      return if listed_together?(rule, other)

      attributes = field_values(rule).keys & field_values(other).keys
      return if attributes.empty?

      shared = matches[rule.id] & matches[other.id]
      same_text = same_text?(rule, other)
      return if shared.empty? && !same_text

      Overlap.new(rule: rule, other: other, attributes: attributes, shared_count: shared.size,
        match_count: matches[rule.id].size, same_text: same_text)
    end

    def listed_together?(rule, other)
      (duplicates + conflicts.map(&:rules)).any? { |group| group.include?(rule) && group.include?(other) }
    end

    def same_text?(rule, other)
      texts(rule).any? { |text| texts(other).any? { |other_text| text.include?(other_text) || other_text.include?(text) } }
    end

    # The text a match must contain, case-folded, with a merchant condition
    # read as its merchant's name.
    def texts(rule)
      @texts ||= {}
      @texts[rule.id] ||= leaf_conditions(rule).filter_map do |condition|
        next unless TEXT_OPERATORS.include?(condition.operator)

        text = case condition.condition_type
        when "transaction_name" then condition.value
        when "transaction_merchant" then merchant_names[condition.value.to_s]
        end
        text.to_s.gsub(/\s+/, " ").strip.downcase.presence
      end
    end

    def merchant_names
      @merchant_names ||= begin
        ids = rules.flat_map { |rule| leaf_conditions(rule) }
          .select { |condition| condition.condition_type == "transaction_merchant" }.map(&:value).compact_blank.uniq
        Merchant.where(id: ids.select { |id| UuidFormat.valid?(id) }).pluck(:id, :name).to_h { |id, name| [ id.to_s, name ] }
      end
    end

    # The fields a rule claims, with the value it sets each to.
    def field_values(rule)
      @field_values ||= {}
      @field_values[rule.id] ||= rule.actions.each_with_object({}) do |action, values|
        next unless reserves_claims?(action)

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
        .flat_map { |condition| condition.compound? && condition.operator == "and" ? condition.sub_conditions.to_a : [ condition ] }
        .map do |condition|
          if condition.compound?
            [ "compound", condition.operator.to_s, condition_signature(condition.sub_conditions) ]
          else
            [ condition.condition_type.to_s, condition.operator.to_s, condition_value(condition) ]
          end
        end
        .sort_by(&:inspect)
    end

    # Normalised the way Rule::ConditionFilter matches it: whitespace is
    # collapsed in text, except in a pattern.
    def condition_value(condition)
      return "" if Rule::ConditionFilter::VALUELESS_OPERATORS.include?(condition.operator)

      value = condition.value.to_s
      return value if condition.regex?

      value = value.gsub(/\s+/, " ").strip if condition.filter.type == "text"
      CASE_INSENSITIVE_OPERATORS.include?(condition.operator) ? value.downcase : value
    end

    def action_signature(rule)
      rule.actions.reject(&:marked_for_destruction?).map { |action| [ action.action_type.to_s, action.value.to_s ] }.sort
    end

    def leaf_conditions(rule)
      rule.conditions.flat_map { |condition| condition.compound? ? condition.sub_conditions.to_a : [ condition ] }
    end
end
