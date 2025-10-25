class AddUsageToMessages < ActiveRecord::Migration[7.2]
  def change
    change_table :messages, bulk: true do |t|
      t.string :endpoint
      t.integer :prompt_tokens, null: false, default: 0
      t.integer :completion_tokens, null: false, default: 0
      t.integer :total_tokens, null: false, default: 0
      t.decimal :estimated_cost, precision: 10, scale: 6
    end
  end
end
