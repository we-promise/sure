# What the rules run so far have claimed (see Rule::Runner): per attribute, the
# transactions a rule already set it for, and the transactions a rule with
# stop_processing matched. Rules further down leave both alone.
class Rule::Runner::Claims
  attr_reader :claimed_ids, :stopped_ids

  def initialize
    @claimed_ids = Hash.new { |hash, attribute| hash[attribute] = Set.new }
    @stopped_ids = Set.new
  end

  # The rule's matches without those a rule above stopped. within_ids limits
  # the matches to those transactions (see Rule#matching_scope).
  def unstopped_scope(rule, within_ids: nil)
    Rule.excluding_transaction_ids(rule.matching_scope(within_ids: within_ids), stopped_ids)
  end

  def record(rule, matched_ids)
    rule.actions.each do |action|
      reserved_attributes(action).each { |attribute| claimed_ids[attribute].merge(matched_ids) }
    end

    stopped_ids.merge(matched_ids) if rule.stop_processing?
  end

  private
    # An action that cannot be resolved (e.g. an unknown action_type from an
    # import) sets nothing, so it claims nothing and must not abort the run.
    def reserved_attributes(action)
      return [] unless action.reserves_claimed_attributes?

      action.claimed_attributes
    rescue => e
      Rails.logger.error("Rule::Runner could not read claims of action #{action.id}: #{e.class}: #{e.message}")
      []
    end
end
