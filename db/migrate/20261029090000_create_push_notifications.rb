class CreatePushNotifications < ActiveRecord::Migration[8.1]
  def change
    add_column :insights, :notification_version, :integer, default: 1, null: false

    create_table :web_push_subscriptions, id: :uuid do |t|
      t.references :user, null: false, type: :uuid, foreign_key: true
      # Session cleanup can delete rows without callbacks; the browser
      # subscription goes with its session.
      t.references :session, null: false, type: :uuid, foreign_key: { on_delete: :cascade }
      t.text :endpoint, null: false
      t.string :endpoint_digest, null: false
      t.text :p256dh, null: false
      t.text :auth, null: false
      t.datetime :last_test_requested_at
      t.timestamps
    end
    add_index :web_push_subscriptions, :endpoint_digest, unique: true

    # One delivery ledger for every push channel. The subscription is
    # polymorphic, so it has no foreign key.
    create_table :push_deliveries, id: :uuid do |t|
      t.references :subscription, polymorphic: true, null: false, type: :uuid
      t.references :insight, type: :uuid, foreign_key: true
      t.integer :insight_version
      t.string :status, null: false, default: "pending"
      t.datetime :enqueued_at
      t.datetime :attempted_at
      t.integer :provider_attempts, null: false, default: 0
      t.timestamps
    end
    add_index :push_deliveries, [ :subscription_type, :subscription_id, :insight_id, :insight_version ],
      unique: true, name: "index_push_deliveries_on_channel_insight_version"
    add_index :push_deliveries, [ :status, :updated_at ]
    add_check_constraint :push_deliveries,
      "status IN ('pending', 'accepted', 'skipped', 'rejected', 'failed', 'enqueue_failed')",
      name: "chk_push_deliveries_status"
    add_check_constraint :push_deliveries,
      "(insight_id IS NULL AND insight_version IS NULL) OR (insight_id IS NOT NULL AND insight_version IS NOT NULL AND insight_version > 0)",
      name: "chk_push_deliveries_insight_version"
    add_check_constraint :push_deliveries, "provider_attempts >= 0", name: "chk_push_deliveries_provider_attempts"
  end
end
