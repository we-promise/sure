class AddCopyPortfoliosToEtoro < ActiveRecord::Migration[8.1]
  def change
    add_reference :etoro_accounts, :main_account, type: :uuid, index: false, foreign_key: { to_table: :etoro_accounts, on_delete: :cascade }
    add_column :etoro_accounts, :mirror_id, :bigint
    add_index :etoro_accounts, [ :main_account_id, :mirror_id ], unique: true, where: "main_account_id IS NOT NULL", name: "index_etoro_accounts_on_main_account_and_mirror"

    create_table :etoro_portfolio_snapshots, id: :uuid do |t|
      t.references :etoro_account, type: :uuid, null: false, index: false, foreign_key: { on_delete: :cascade }
      t.bigint :mirror_id, null: false
      t.date :date, null: false
      t.decimal :total, precision: 19, scale: 4, null: false
      t.decimal :cash, precision: 19, scale: 4, null: false
      t.decimal :deposits, precision: 19, scale: 4
      t.decimal :withdrawals, precision: 19, scale: 4
      t.boolean :closed, null: false, default: false
      t.string :username
      t.jsonb :holdings, null: false, default: {}
      t.timestamps
    end
    add_index :etoro_portfolio_snapshots, [ :etoro_account_id, :mirror_id, :date ], unique: true, name: "index_etoro_portfolio_snapshots_on_part_and_date"
  end
end
