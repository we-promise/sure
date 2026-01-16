class CreateTraderepublicItems < ActiveRecord::Migration[7.2]
  def change
    create_table :traderepublic_items, id: :uuid do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid
      t.string :name, null: false
      t.string :phone_number, null: false
      t.string :pin, null: false
      t.string :status, null: false, default: "good"
      t.boolean :scheduled_for_deletion, null: false, default: false
      t.boolean :pending_account_setup, null: false, default: false
      t.datetime :sync_start_date, null: false

      t.index :status
      t.jsonb :raw_payload, null: false

      t.timestamps
    end
  end
end
