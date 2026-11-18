class GeneralizeWebPushDeliveryLedgerToPushDeliveries < ActiveRecord::Migration[8.1]
  def up
    rename_table :web_push_deliveries, :push_deliveries

    rename_column :push_deliveries, :web_push_subscription_id, :subscription_id
    add_column :push_deliveries, :subscription_type, :string, null: false, default: "WebPushSubscription"

    # Polymorphic subscriptions point at different tables per channel, so the
    # FK inherited from the web-push-only ledger cannot survive the rename.
    remove_foreign_key :push_deliveries, column: :subscription_id

    # The single-column subscription index is superseded by the polymorphic
    # one; rename_table already renamed the surviving indexes to the new table
    # prefix, so only these two need explicit attention.
    remove_index :push_deliveries, :subscription_id
    add_index :push_deliveries, [ :subscription_type, :subscription_id ],
      name: "index_push_deliveries_on_subscription"

    # Dedupe must distinguish channels: the unique index gains the type.
    remove_index :push_deliveries, [ :subscription_id, :insight_id, :insight_version ]
    add_index :push_deliveries, [ :subscription_type, :subscription_id, :insight_id, :insight_version ],
      unique: true, name: "index_push_deliveries_on_channel_insight_version"

    restamp_push_delivery_constraints
  end

  def down
    remove_index :push_deliveries, name: "index_push_deliveries_on_channel_insight_version"
    remove_index :push_deliveries, name: "index_push_deliveries_on_subscription"
    add_index :push_deliveries, [ :subscription_id, :insight_id, :insight_version ],
      unique: true, name: "index_push_deliveries_on_insight_version"
    add_index :push_deliveries, :subscription_id, name: "index_push_deliveries_on_subscription_id"
    rename_column :push_deliveries, :subscription_id, :web_push_subscription_id
    remove_column :push_deliveries, :subscription_type

    restamp_push_delivery_constraints

    add_foreign_key :push_deliveries, :web_push_subscriptions
    rename_table :push_deliveries, :web_push_deliveries
  end

  private
    def restamp_push_delivery_constraints
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
