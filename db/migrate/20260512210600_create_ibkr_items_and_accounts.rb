class CreateIbkrItemsAndAccounts < ActiveRecord::Migration[7.2]
  def change
    create_table :ibkr_items, id: :uuid do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid
      t.string :name
      t.string :status, default: "good", null: false
      t.boolean :scheduled_for_deletion, default: false, null: false
      t.boolean :pending_account_setup, default: false, null: false
      t.jsonb :raw_payload
      t.string :query_id
      t.string :token

      t.timestamps
    end

    add_index :ibkr_items, :status

    create_table :ibkr_accounts, id: :uuid do |t|
      t.references :ibkr_item, null: false, foreign_key: true, type: :uuid
      t.string :name
      t.string :ibkr_account_id
      t.string :currency
      t.decimal :current_balance, precision: 19, scale: 4
      t.decimal :cash_balance, precision: 19, scale: 4
      t.jsonb :institution_metadata
      t.jsonb :raw_holdings_payload, default: [], null: false
      t.jsonb :raw_activities_payload, default: {}, null: false
      t.jsonb :raw_cash_report_payload, default: [], null: false
      t.date :report_date
      t.datetime :last_holdings_sync
      t.datetime :last_activities_sync

      t.timestamps
    end

    add_index :ibkr_accounts, [ :ibkr_item_id, :ibkr_account_id ],
      unique: true,
      where: "(ibkr_account_id IS NOT NULL)",
      name: "index_ibkr_accounts_on_item_and_ibkr_account_id"
  end
end
