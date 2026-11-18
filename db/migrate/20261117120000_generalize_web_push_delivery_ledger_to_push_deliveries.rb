class GeneralizeWebPushDeliveryLedgerToPushDeliveries < ActiveRecord::Migration[8.1]
  def change
    rename_table :web_push_deliveries, :push_deliveries

    rename_column :push_deliveries, :web_push_subscription_id, :subscription_id
    add_column :push_deliveries, :subscription_type, :string, null: false, default: "WebPushSubscription"

    rename_index :push_deliveries, "index_web_push_deliveries_on_insight_version",
      "index_push_deliveries_on_insight_version"
    rename_index :push_deliveries, "index_web_push_deliveries_on_status_and_updated_at",
      "index_push_deliveries_on_status_and_updated_at"
    add_index :push_deliveries, [ :subscription_type, :subscription_id ],
      name: "index_push_deliveries_on_subscription"

    remove_check_constraint :push_deliveries, name: "chk_web_push_deliveries_status"
    add_check_constraint :push_deliveries,
      "status IN ('pending', 'accepted', 'skipped', 'rejected', 'failed', 'enqueue_failed')",
      name: "chk_push_deliveries_status"
    remove_check_constraint :push_deliveries, name: "chk_web_push_deliveries_insight_version"
    add_check_constraint :push_deliveries,
      "(insight_id IS NULL AND insight_version IS NULL) OR (insight_id IS NOT NULL AND insight_version IS NOT NULL AND insight_version > 0)",
      name: "chk_push_deliveries_insight_version"
    remove_check_constraint :push_deliveries, name: "chk_web_push_deliveries_provider_attempts"
    add_check_constraint :push_deliveries, "provider_attempts >= 0",
      name: "chk_push_deliveries_provider_attempts"
  end
end
