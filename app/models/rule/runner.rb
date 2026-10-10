# Runs a family's rules one after another, top to bottom (Rule#position).
#
# - Top rule wins: once a rule sets an attribute on a transaction, rules further
#   down leave that attribute alone in the same run, even when the value was
#   already set or the attribute is locked. Tags are additive and claim nothing.
# - Stop processing: a transaction matched by a rule with stop_processing is not
#   touched by any rule further down.
#
# Rules above the ones to execute are only matched (not executed), so applying a
# single rule behaves exactly like its turn in the full run. Inactive rules
# above it are skipped because they don't run nightly either.
#
# One run per family at a time, guarded by a PostgreSQL advisory lock. A busy
# lock raises LockBusy so the calling job can retry instead of dropping the run.
class Rule::Runner
  LockBusy = Class.new(StandardError)

  attr_reader :errors

  def self.advisory_lock_key(family_id)
    Digest::MD5.hexdigest("rule_runner:#{family_id}").to_i(16) % (2**62)
  end

  def initialize(family, rules:, execution_type:, ignore_attribute_locks: false)
    @family = family
    @rule_ids = rules.map(&:id).to_set
    @execution_type = execution_type
    @ignore_attribute_locks = ignore_attribute_locks
    @claimed_ids = Hash.new { |hash, attribute| hash[attribute] = Set.new }
    @stopped_ids = Set.new
    @errors = []
  end

  # Returns the RuleRun records created, one per executed rule.
  def run
    return [] if rule_ids.empty?

    rule_runs = nil
    acquired = with_family_lock { rule_runs = run_rules }
    raise LockBusy, "Rules are already running for family #{family.id}" unless acquired

    rule_runs
  end

  private
    attr_reader :family, :rule_ids, :execution_type, :ignore_attribute_locks, :claimed_ids, :stopped_ids

    def run_rules
      rule_runs = []
      remaining_ids = rule_ids.dup

      family.rules.ordered.includes(:family, :actions, conditions: :sub_conditions).each do |rule|
        break if remaining_ids.empty?

        if remaining_ids.delete?(rule.id)
          rule_runs << execute(rule)
        elsif rule.active?
          match_without_executing(rule)
        end
      end

      rule_runs
    end

    # A rule above that cannot even be matched claims nothing; it must not
    # keep the rules below it from running.
    def match_without_executing(rule)
      record_claims(rule, unstopped_scope(rule).pluck(:id))
    rescue => e
      Rails.logger.error("Rule::Runner could not match rule #{rule.id}: #{e.class}: #{e.message}")
    end

    def unstopped_scope(rule)
      Rule.excluding_transaction_ids(rule.matching_scope, stopped_ids)
    end

    def record_claims(rule, matched_ids)
      rule.actions.each do |action|
        next unless action.reserves_claimed_attributes?

        action.claimed_attributes.each { |attribute| claimed_ids[attribute].merge(matched_ids) }
      end

      stopped_ids.merge(matched_ids) if rule.stop_processing?
    end

    def execute(rule)
      executed_at = Time.current
      matched_ids = []
      rule_run = nil

      begin
        scope = unstopped_scope(rule)
        matched_ids = scope.pluck(:id)

        rule_run = RuleRun.create!(
          rule: rule,
          rule_name: rule.name,
          execution_type: execution_type,
          status: "pending",
          transactions_queued: matched_ids.size,
          transactions_processed: 0,
          transactions_modified: 0,
          pending_jobs_count: 0,
          executed_at: executed_at
        )

        result = rule.apply(
          ignore_attribute_locks: ignore_attribute_locks,
          rule_run: rule_run,
          scope: scope,
          claimed_ids: claimed_ids
        )

        rule_run.update!(**run_counts(result, queued: matched_ids.size, rule: rule))
      rescue => e
        rule_run = record_failure(rule, rule_run, e, executed_at: executed_at, queued: matched_ids.size)
      ensure
        # Claims hold even when the rule failed halfway, so a rule further down
        # never overwrites what this rule may already have set.
        record_claims(rule, matched_ids)
      end

      rule_run
    end

    def run_counts(result, queued:, rule:)
      if result.is_a?(Hash) && result[:async]
        # The async jobs report the modified count back via RuleRun#complete_job!
        { status: "pending", transactions_processed: result[:modified_count] || 0, pending_jobs_count: result[:jobs_count] || 0 }
      elsif result.is_a?(Integer)
        { status: "success", transactions_processed: queued, transactions_modified: result }
      else
        Rails.logger.warn("Rule::Runner: Unexpected result type from rule.apply: #{result.class} for rule #{rule.id}")
        { status: "success" }
      end
    end

    def record_failure(rule, rule_run, error, executed_at:, queued:)
      errors << error
      error_message = "#{error.class}: #{error.message}"
      Rails.logger.error("Rule::Runner failed for rule #{rule.id}: #{error_message}")

      if rule_run
        rule_run.update(status: "failed", error_message: error_message)
        rule_run
      else
        RuleRun.create!(
          rule: rule,
          rule_name: rule.name,
          execution_type: execution_type,
          status: "failed",
          transactions_queued: queued,
          transactions_processed: 0,
          transactions_modified: 0,
          pending_jobs_count: 0,
          executed_at: executed_at,
          error_message: error_message
        )
      end
    rescue => e
      Rails.logger.error("Rule::Runner: Failed to record RuleRun for rule #{rule.id}: #{e.message}")
      rule_run
    end

    # Same pattern as RecurringTransaction::Pipeline.with_family_lock: one
    # leased connection for lock and unlock, because the unlock must run on the
    # PostgreSQL session that took the lock.
    def with_family_lock
      lock_key = self.class.advisory_lock_key(family.id)
      connection = ActiveRecord::Base.lease_connection
      acquired = connection.select_value(
        ActiveRecord::Base.sanitize_sql_array([ "SELECT pg_try_advisory_lock(?)", lock_key ])
      )

      return false unless acquired

      begin
        yield
      ensure
        connection.execute(
          ActiveRecord::Base.sanitize_sql_array([ "SELECT pg_advisory_unlock(?)", lock_key ])
        )
      end
      true
    end
end
