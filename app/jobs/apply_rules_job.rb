# Applies all active rules of a family in order after a sync.
class ApplyRulesJob < ApplicationJob
  queue_as :medium_priority

  retry_on Rule::Runner::LockBusy, wait: 30.seconds, attempts: 20

  # A failing rule is recorded as a failed RuleRun and the remaining rules still
  # run. The job itself does not fail, because a retry would re-run every rule.
  def perform(family, execution_type: "scheduled")
    Rule::Runner.new(
      family,
      rules: family.rules.where(active: true),
      execution_type: execution_type
    ).run
  end
end
