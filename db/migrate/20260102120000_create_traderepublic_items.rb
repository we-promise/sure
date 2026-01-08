class CreateTraderepublicItems < ActiveRecord::Migration[7.2]
  def change
    create_table :traderepublic_items, id: :uuid do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid
      t.string :name
      t.string :phone_number
      t.string :pin
      t.string :status, default: "good"
      t.boolean :scheduled_for_deletion, default: false
      t.boolean :pending_account_setup, default: false
      t.datetime :sync_start_date

      t.index :status
      t.jsonb :raw_payload

      t.timestamps
    end
  end
end
