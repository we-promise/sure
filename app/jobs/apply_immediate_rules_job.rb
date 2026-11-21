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

    runner = Rule::Runner.new(
      family,
      rules: rules,
      execution_type: "immediate",
      transaction_ids: transaction_ids
    )
    runner.run

    # The AI jobs of a rule offer their own changes once they are done
    # (RuleRun#complete_job!), so only what the run changed itself counts here.
    return unless runner.changed_now_count.positive?

    RuleRun.offer_immediate_result(family)
  end
end
