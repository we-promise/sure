class CreateNotificationDeliveries < ActiveRecord::Migration[7.2]
  def change
    create_table :notification_deliveries, id: :uuid do |t|
      t.references :rule, null: false, foreign_key: { on_delete: :cascade }, type: :uuid
      # Transactions are deleted and re-ingested frequently during syncs, so we
      # cascade rather than block their deletion. Dedup keys on this row id.
      t.references :transaction, null: false, foreign_key: { on_delete: :cascade }, type: :uuid

      t.timestamps
    end

    add_index :notification_deliveries, [ :rule_id, :transaction_id ],
      unique: true, name: "index_notification_deliveries_on_rule_and_transaction"
  end
end
