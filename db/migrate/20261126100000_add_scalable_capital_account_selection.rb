class AddScalableCapitalAccountSelection < ActiveRecord::Migration[8.1]
  def change
    change_column_null :scalable_capital_items, :portfolio_id, true
    add_column :scalable_capital_items, :selected_sources, :jsonb, default: [], null: false
    add_column :scalable_capital_items, :broker_history_version, :integer, default: 0, null: false
    add_column :scalable_capital_accounts, :source_key, :string

    remove_index :scalable_capital_accounts, [ :scalable_capital_item_id, :kind ],
                 unique: true, name: "index_scalable_capital_accounts_on_item_and_kind"
    add_index :scalable_capital_accounts, [ :scalable_capital_item_id, :kind, :source_key ],
              unique: true, nulls_not_distinct: true, name: "index_scalable_capital_accounts_on_source"
  end
end
