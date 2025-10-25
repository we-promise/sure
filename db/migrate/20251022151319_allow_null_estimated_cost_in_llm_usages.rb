class AllowNullEstimatedCostInLlmUsages < ActiveRecord::Migration[7.2]
  def change
    change_column_null :llm_usages, :estimated_cost, true
    change_column_default :llm_usages, :estimated_cost, from: 0.0, to: nil
  end
end
