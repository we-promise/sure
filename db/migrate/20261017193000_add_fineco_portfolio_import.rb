class AddFinecoPortfolioImport < ActiveRecord::Migration[8.1]
  def change
    change_table :fineco_items, bulk: true do |t|
      t.text :bank_account_number
      t.text :dossier_identity
      t.string :status, null: false, default: "good"
      t.datetime :portfolio_snapshot_at
      t.string :last_sync_error_code
    end

    add_check_constraint :fineco_items,
                         "status IN ('good', 'requires_update')",
                         name: "chk_fineco_items_status"

    create_table :fineco_accounts, id: :uuid do |t|
      t.references :fineco_item, type: :uuid, null: false,
                                 foreign_key: { on_delete: :cascade }
      t.string :external_id, null: false
      t.string :name, null: false
      t.string :currency, limit: 3, null: false
      t.jsonb :raw_position_metadata, default: {}, null: false
      t.date :last_snapshot_date
      t.datetime :last_snapshot_at

      t.timestamps
    end

    add_index :fineco_accounts, [ :fineco_item_id, :external_id ], unique: true
    add_check_constraint :fineco_accounts, "currency = 'EUR'", name: "chk_fineco_accounts_currency_eur"
  end
end
