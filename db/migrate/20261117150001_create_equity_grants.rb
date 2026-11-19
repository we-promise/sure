class CreateEquityGrants < ActiveRecord::Migration[8.1]
  def change
    create_table :equity_grants, id: :uuid do |t|
      t.references :account, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :account_statement, type: :uuid, foreign_key: { on_delete: :nullify }
      t.string :grant_identifier, limit: 100
      t.string :ticker, limit: 20, null: false
      t.string :grant_type, null: false, default: "rsu"
      t.date :grant_date
      t.decimal :total_units, precision: 24, scale: 6
      t.string :notes, limit: 500
      t.string :source, null: false, default: "manual"
      t.timestamps
    end

    add_index :equity_grants, [ :account_id, :grant_identifier ], unique: true, where: "grant_identifier IS NOT NULL"

    create_table :equity_vests, id: :uuid do |t|
      t.references :equity_grant, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :account_statement, type: :uuid, foreign_key: { on_delete: :nullify }
      t.date :vest_date, null: false
      t.decimal :units, precision: 24, scale: 6, null: false
      # Filled in once the vest has happened, from the release confirmation.
      t.decimal :units_withheld, precision: 24, scale: 6
      t.decimal :net_proceeds, precision: 19, scale: 4
      t.string :currency, limit: 3
      t.string :source, null: false, default: "manual"
      t.timestamps
    end

    add_index :equity_vests, [ :equity_grant_id, :vest_date ]
  end
end
