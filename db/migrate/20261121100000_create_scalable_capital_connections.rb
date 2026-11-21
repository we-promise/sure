class CreateScalableCapitalConnections < ActiveRecord::Migration[8.1]
  def change
    create_table :scalable_capital_items, id: :uuid do |t|
      t.references :family, type: :uuid, null: false, foreign_key: true, index: { unique: true }
      t.references :owner, type: :uuid, foreign_key: { to_table: :users, on_delete: :nullify }
      t.string :portfolio_id, null: false
      t.string :savings_id
      t.string :broker_account_id
      t.string :status, default: "good", null: false
      t.datetime :broker_synced_through
      t.datetime :savings_synced_through
      t.jsonb :security_ids, default: {}, null: false
      t.timestamps
    end

    create_table :scalable_capital_accounts, id: :uuid do |t|
      t.references :scalable_capital_item, type: :uuid, null: false, foreign_key: true, index: false
      t.string :kind, null: false
      t.timestamps

      t.index [ :scalable_capital_item_id, :kind ], unique: true, name: "index_scalable_capital_accounts_on_item_and_kind"
    end
  end
end
