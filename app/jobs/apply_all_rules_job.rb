class ApplyAllRulesJob < ApplicationJob
  queue_as :medium_priority

  retry_on Rule::Runner::LockBusy, wait: 30.seconds, attempts: 20

  def perform(family, execution_type: "manual", user_id: nil)
    Rule::Runner.new(
      family,
      rules: family.rules,
      execution_type: execution_type,
      ignore_attribute_locks: true,
      user: family.users.find_by(id: user_id)
    ).run
  end
end
