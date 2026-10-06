# Applies a single rule ("Apply rule" in the UI). Rules above it still count, so
# it respects "top rule wins" and "stop processing" like the full run.
class RuleJob < ApplicationJob
  queue_as :medium_priority

  retry_on Rule::Runner::LockBusy, wait: 30.seconds, attempts: 20

  def perform(rule, ignore_attribute_locks: false, execution_type: "manual")
    runner = Rule::Runner.new(
      rule.family,
      rules: [ rule ],
      execution_type: execution_type,
      ignore_attribute_locks: ignore_attribute_locks
    )
    runner.run

    # The RuleRun records the failure; re-raise so the job is marked failed.
    raise runner.errors.first if runner.errors.any?
  end
end
