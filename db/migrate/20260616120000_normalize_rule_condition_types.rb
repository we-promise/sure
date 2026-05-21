class NormalizeRuleConditionTypes < ActiveRecord::Migration[7.2]
  def up
    execute <<~SQL
      UPDATE rule_conditions
      SET condition_type = 'transaction_name'
      WHERE condition_type = 'name'
    SQL
  end

  def down
  end
end
