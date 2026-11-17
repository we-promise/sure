class ApplyAllRulesJob < ApplicationJob
  queue_as :medium_priority

  retry_on Rule::Runner::LockBusy, wait: 30.seconds, attempts: 20

  def perform(family, execution_type: "manual", user: nil)
    Rule::Runner.new(
      family,
      rules: family.rules,
      execution_type: execution_type,
      ignore_attribute_locks: true,
      user: user
    ).run
  end
end
