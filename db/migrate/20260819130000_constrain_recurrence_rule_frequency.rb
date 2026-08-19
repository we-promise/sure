class ConstrainRecurrenceRuleFrequency < ActiveRecord::Migration[7.2]
  # The enum raises only in Ruby; a row written past the model (insert_all, a
  # rake task, a console session) could carry a frequency the schedule engine
  # cannot generate occurrences for. No values change.
  def up
    add_check_constraint :recurrence_rules,
                         "frequency IN ('weekly', 'monthly', 'yearly')",
                         name: "chk_recurrence_rules_frequency"
  end

  def down
    remove_check_constraint :recurrence_rules, name: "chk_recurrence_rules_frequency"
  end
end
