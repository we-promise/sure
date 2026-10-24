# Applies the "apply immediately" rules to transactions a person just created or
# changed. Like "Apply rule", the active rules above them run first on the same
# transactions, so each immediate rule gives the result of its turn in the
# nightly run. Rules below the last immediate rule wait for the nightly run.
class ApplyImmediateRulesJob < ApplicationJob
  queue_as :medium_priority

  retry_on Rule::Runner::LockBusy, wait: 30.seconds, attempts: 20

  def perform(family, transaction_ids:)
    rules = family.rules.applied_immediately
    return if rules.none?

    rule_runs = Rule::Runner.new(
      family,
      rules: rules,
      execution_type: "immediate",
      transaction_ids: transaction_ids
    ).run

    # A run with AI actions is still pending here and counts what its other
    # actions changed as processed (Rule::Runner#run_counts); its AI jobs offer
    # their own changes once they are done (RuleRun#complete_job!).
    changed = rule_runs.any? do |rule_run|
      (rule_run.pending? ? rule_run.transactions_processed : rule_run.transactions_modified).to_i.positive?
    end
    return unless changed

    RuleRun.offer_immediate_result(family)
  end
end
