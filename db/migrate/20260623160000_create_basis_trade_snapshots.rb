class CreateBasisTradeSnapshots < ActiveRecord::Migration[7.2]
  def change
    create_table :basis_trade_snapshots, id: :uuid do |t|
      t.references :family, null: false, foreign_key: { on_delete: :cascade }, type: :uuid
      t.datetime :recorded_at, null: false
      t.bigint :spot_leg_cents, null: false, default: 0
      t.bigint :short_leg_cents, null: false, default: 0
      t.bigint :funding_accrued_cents, null: false, default: 0
      t.bigint :rewards_accrued_cents, null: false, default: 0
      t.string :currency, null: false
      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end

    add_index :basis_trade_snapshots, :recorded_at
    add_index :basis_trade_snapshots, [ :family_id, :recorded_at ], unique: true
  end
end
