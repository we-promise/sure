# A folder for rules, so a long rule list stays readable. It only arranges the
# list: rules still run as one list from top to bottom (see Rule::Layout), and
# a group has no state of its own.
class RuleGroup < ApplicationRecord
  belongs_to :family
  has_many :rules, dependent: :nullify

  scope :alphabetically, -> { order(Arel.sql("LOWER(name)"), :id) }

  before_validation :normalize_name
  before_create :assign_next_position

  validates :name, presence: true, length: { maximum: 100 }, if: -> { name.to_s.valid_encoding? }
  validates :name, uniqueness: { scope: :family_id }, if: -> { DatabaseTextValidator.acceptable?(name) }
  validates_with DatabaseTextValidator, attributes: %i[name]

  # The family's group with that name, created if missing. A group created at
  # the same moment by another request is found instead of failing.
  def self.find_or_create_named!(name)
    find_by(name: name) || create_or_find_by!(name: name)
  end

  # Switches every rule of the group on or off, one by one, so each rule runs
  # its own callbacks (switching a rule on takes its email baseline). Returns
  # the rules left as they were: invalid ones, and those kept off because that
  # baseline timed out.
  def switch_rules(active)
    rules.ordered.to_a.reject do |rule|
      rule.update(active: active) && !rule.notification_baseline_timed_out?
    end
  end

  private
    def assign_next_position
      self.position = Rule.next_position_for(family)
    end

    def normalize_name
      self.name = name.strip if name.is_a?(String) && name.valid_encoding? && !name.include?("\0")
    end
end
