class NormalizeLegacyRuleConditionTypes < ActiveRecord::Migration[7.2]
  def up
    execute <<~SQL
      UPDATE rule_conditions
      SET condition_type = 'transaction_name'
      WHERE condition_type IN ('name', 'transaction_details');
    SQL
  end

  def down
    # no-op: legacy values are intentionally normalized forward
  end
end
