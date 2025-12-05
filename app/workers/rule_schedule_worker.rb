class RuleScheduleWorker
  include Sidekiq::Worker

  sidekiq_options queue: "scheduled"

  def perform(rule_id)
    rule = Rule.find_by(id: rule_id)
    return unless rule&.schedule_enabled? && rule.active?

    RuleJob.set(queue: :scheduled).perform_later(rule_id, ignore_attribute_locks: false)
  end
end
