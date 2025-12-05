require "fugit"
require "sidekiq/cron/job"

class Rule < ApplicationRecord
  UnsupportedResourceTypeError = Class.new(StandardError)

  belongs_to :family
  has_many :conditions, dependent: :destroy
  has_many :actions, dependent: :destroy

  accepts_nested_attributes_for :conditions, allow_destroy: true
  accepts_nested_attributes_for :actions, allow_destroy: true

  before_validation :normalize_name

  validates :resource_type, presence: true
  validates :name, length: { minimum: 1 }, allow_nil: true
  validate :no_nested_compound_conditions
  validate :valid_schedule_when_enabled

  # Every rule must have at least 1 action
  validate :min_actions
  validate :no_duplicate_actions

  after_commit :sync_cron_schedule, if: :schedule_state_changed?, on: [ :create, :update ]
  after_commit :remove_cron_schedule, on: :destroy, if: :scheduled_before_change?

  def action_executors
    registry.action_executors
  end

  def condition_filters
    registry.condition_filters
  end

  def registry
    @registry ||= case resource_type
    when "transaction"
      Rule::Registry::TransactionResource.new(self)
    else
      raise UnsupportedResourceTypeError, "Unsupported resource type: #{resource_type}"
    end
  end

  def affected_resource_count
    matching_resources_scope.count
  end

  def apply(ignore_attribute_locks: false)
    actions.each do |action|
      action.apply(matching_resources_scope, ignore_attribute_locks: ignore_attribute_locks)
    end
  end

  def apply_later(ignore_attribute_locks: false)
    RuleJob.perform_later(self, ignore_attribute_locks: ignore_attribute_locks)
  end

  def primary_condition_title
    return "No conditions" if conditions.none?

    first_condition = conditions.first
    if first_condition.compound? && first_condition.sub_conditions.any?
      first_sub_condition = first_condition.sub_conditions.first
      "If #{first_sub_condition.filter.label.downcase} #{first_sub_condition.operator} #{first_sub_condition.value_display}"
    else
      "If #{first_condition.filter.label.downcase} #{first_condition.operator} #{first_condition.value_display}"
    end
  end

  private
    def matching_resources_scope
      scope = registry.resource_scope

      # 1. Prepare the query with joins required by conditions
      conditions.each do |condition|
        scope = condition.prepare(scope)
      end

      # 2. Apply the conditions to the query
      conditions.each do |condition|
        scope = condition.apply(scope)
      end

      scope
    end

    def min_actions
      if actions.reject(&:marked_for_destruction?).empty?
        errors.add(:base, "must have at least one action")
      end
    end

    def no_duplicate_actions
      action_types = actions.reject(&:marked_for_destruction?).map(&:action_type)

      errors.add(:base, "Rule cannot have duplicate actions #{action_types.inspect}") if action_types.uniq.count != action_types.count
    end

    # Validation: To keep rules simple and easy to understand, we don't allow nested compound conditions.
    def no_nested_compound_conditions
      return true if conditions.none? { |condition| condition.compound? }

      conditions.each do |condition|
        if condition.compound?
          if condition.sub_conditions.any? { |sub_condition| sub_condition.compound? }
            errors.add(:base, "Compound conditions cannot be nested")
          end
        end
      end
    end

    def normalize_name
      self.name = nil if name.is_a?(String) && name.strip.empty?
    end

    def schedule_state_changed?
      saved_change_to_schedule_cron? || saved_change_to_schedule_enabled? || saved_change_to_active?
    end

    def scheduled_before_change?
      schedule_enabled_was = saved_change_to_schedule_enabled? ? schedule_enabled_before_last_save : schedule_enabled?
      active_was = saved_change_to_active? ? active_before_last_save : active?
      cron_was_present = if saved_change_to_schedule_cron?
        schedule_cron_before_last_save.present?
      else
        schedule_cron.present?
      end

      schedule_enabled_was && active_was && cron_was_present
    end

    def valid_schedule_when_enabled
      return unless schedule_enabled?

      if schedule_cron.blank?
        errors.add(:schedule_cron, "can't be blank when scheduling is enabled")
        return
      end

      parsed_cron = begin
        Fugit::Cron.parse(schedule_cron)
      rescue StandardError
        nil
      end

      errors.add(:schedule_cron, "is invalid") unless parsed_cron
    end

    def cron_job_name
      "rule-#{id}"
    end

    def sync_cron_schedule
      if schedule_enabled? && active? && schedule_cron.present?
        Sidekiq::Cron::Job.create(
          name: cron_job_name,
          cron: schedule_cron,
          class: "RuleScheduleWorker",
          args: [ id ],
          description: "Scheduled rule #{id}",
          queue: "scheduled"
        )
      elsif scheduled_before_change?
        remove_cron_schedule
      end
    rescue StandardError => e
      Rails.logger.error("Failed to sync schedule for rule #{id}: #{e.message}")
    end

    def remove_cron_schedule
      return unless id

      Sidekiq::Cron::Job.destroy(cron_job_name)
    rescue StandardError => e
      Rails.logger.error("Failed to remove schedule for rule #{id}: #{e.message}")
    end
end
