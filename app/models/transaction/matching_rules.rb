# The rules whose conditions match one transaction as it is now, in the order
# they run, and the attributes they fight over. Computed on demand for the
# transaction drawer; nothing is stored.
#
# Every rule is checked against this one transaction in a single query: each
# rule's own matching scope, narrowed to the transaction, is one branch of a
# UNION ALL. A regex condition resolves its matches before the scope is built
# (Rule#matching_scope), so a rule with one costs a query of its own, on this
# row alone.
#
# The rules are checked against the transaction as stored. In a real run a rule
# higher up can change the fields a rule further down reads (e.g. a rename), so
# this answers which rules match now, not what the next run will do.
class Transaction::MatchingRules
  # Attributes kept on the entry rather than the transaction, locks included.
  ENTRY_ATTRIBUTES = %i[name excluded].freeze

  def initialize(transaction, rules:)
    @transaction = transaction
    @candidate_rules = rules
  end

  def rules
    @matching_rules ||= begin
      candidates = candidate_rules.includes(:actions, conditions: :sub_conditions).ordered.to_a
      matched_ids = matching_rule_ids(candidates)
      candidates.select { |rule| matched_ids.include?(rule.id) }.tap { |matched| Rule.share_option_lists(matched) }
    end
  end

  # The active matching rule marked "stop processing" that runs before this
  # one, if any: rules below it never touch the transaction (see Rule::Runner).
  def stopped_by(rule)
    return unless rule.active? && stopper

    stopper if rules.index(stopper) < rules.index(rule)
  end

  # Attributes two or more active matching rules set to different values,
  # each with those rules in run order. The first one wins: rules further down
  # leave an attribute alone once a rule above set it (see Rule::Runner).
  def conflicts
    conflicting_claims.transform_values { |claims| claims.map(&:first) }
  end

  # The attributes this rule would set to another value than the rule above
  # that wins them.
  def overridden_attributes(rule)
    conflicting_claims.filter_map do |attribute, claims|
      winning_value = claims.first.last
      attribute if claims.any? { |claimant, value| claimant == rule && value != winning_value }
    end
  end

  # Attributes matching rules would set that a person set by hand. The nightly
  # run leaves those alone; only applying a rule by hand overrides them.
  def locked_attributes
    claims_by_attribute.keys.select do |attribute|
      (attribute.in?(ENTRY_ATTRIBUTES) ? transaction.entry : transaction).locked?(attribute)
    end
  end

  private
    attr_reader :transaction, :candidate_rules

    def stopper
      return @stopper if defined?(@stopper)

      @stopper = rules.find { |rule| rule.active? && rule.stop_processing? }
    end

    # { attribute => [[rule, what it sets], ...] }, in run order, for the
    # attributes active matching rules set to different values.
    def conflicting_claims
      @conflicting_claims ||= claims_by_attribute.select { |_attribute, claims| claims.map(&:last).uniq.size > 1 }
    end

    def claims_by_attribute
      @claims_by_attribute ||= begin
        reached_rules = rules.select { |rule| rule.active? && stopped_by(rule).nil? }
        reached_rules.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |rule, claims|
          rule.actions.select { |action| reserves_claimed_attributes?(action) }.each do |action|
            action.claimed_attributes.each do |attribute|
              claims[attribute] << [ rule, [ action.action_type, action.value ] ]
            end
          end
        end
      end
    end

    # Whether an action keeps rules below from setting its attributes depends
    # only on its type and value (e.g. that its category still exists), and many
    # rules share one, so each pair is checked once.
    def reserves_claimed_attributes?(action)
      @reserves_claimed_attributes ||= {}
      @reserves_claimed_attributes.fetch([ action.action_type, action.value ]) do |key|
        @reserves_claimed_attributes[key] = action.reserves_claimed_attributes?
      end
    end

    def matching_rule_ids(candidates)
      branches = candidates.filter_map { |rule| branch(rule) }
      return Set.new if branches.empty?

      union = branches.map(&:arel).reduce { |all, branch| Arel::Nodes::UnionAll.new(all, branch) }
      query = Arel::SelectManager.new.project(Arel.star).from(Arel::Nodes::TableAlias.new(union, "matching_rules"))
      Rule.connection.select_values(query).to_set
    end

    # The rule's own matching scope, narrowed to this transaction, reduced to
    # the rule's id: one row when the rule matches, none otherwise.
    def branch(rule)
      rule.matching_scope(only_id: transaction.id, only_entry_id: transaction.entry.id)
          .reselect(Arel::Nodes.build_quoted(rule.id).as("rule_id"))
    # As when the rule runs, a pattern that times out or a condition its filter
    # cannot build (e.g. an imported operator the filter does not support)
    # matches nothing, and the other rules are still checked.
    rescue Rule::SafeRegex::TimeoutError, Rule::ConditionFilter::UnsupportedOperatorError
      nil
    end
end
