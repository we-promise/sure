class CreateWebPushNotifications < ActiveRecord::Migration[8.1]
  def change
    add_column :insights, :notification_version, :integer, default: 1, null: false

    create_table :web_push_subscriptions, id: :uuid do |t|
      t.references :user, null: false, type: :uuid, foreign_key: true
      t.references :session, null: false, type: :uuid, foreign_key: true
      t.text :endpoint, null: false
      t.string :endpoint_digest, null: false
      t.text :p256dh, null: false
      t.text :auth, null: false
      t.datetime :last_test_requested_at
      t.timestamps
    end
    add_index :web_push_subscriptions, :endpoint_digest, unique: true

    create_table :web_push_deliveries, id: :uuid do |t|
      t.references :web_push_subscription, null: false, type: :uuid, foreign_key: true
      t.references :insight, type: :uuid, foreign_key: true
      t.integer :insight_version
      t.string :status, null: false, default: "pending"
      t.datetime :enqueued_at
      t.timestamps
    end
    add_index :web_push_deliveries, [ :web_push_subscription_id, :insight_id, :insight_version ],
      unique: true, name: "index_web_push_deliveries_on_insight_version"
    add_index :web_push_deliveries, [ :status, :updated_at ]
    add_check_constraint :web_push_deliveries,
      "status IN ('pending', 'accepted', 'skipped', 'rejected', 'failed', 'enqueue_failed')",
      name: "chk_web_push_deliveries_status"
    add_check_constraint :web_push_deliveries,
      "(insight_id IS NULL AND insight_version IS NULL) OR (insight_id IS NOT NULL AND insight_version > 0)",
      name: "chk_web_push_deliveries_insight_version"
  end
end
