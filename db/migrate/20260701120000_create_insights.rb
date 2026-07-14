class CreateInsights < ActiveRecord::Migration[7.2]
  def change
    create_table :insights, id: :uuid do |t|
      # index: false — every composite index below leads with family_id, so the
      # auto-created single-column index would be redundant write overhead.
      t.references :family, null: false, type: :uuid, foreign_key: true, index: false
      t.string :insight_type, null: false
      t.string :priority, null: false, default: "medium"
      t.string :status, null: false, default: "active"
      t.string :title, null: false
      t.text :body, null: false
      t.jsonb :metadata, null: false, default: {}
      t.string :currency, null: false, default: "USD"
      t.date :period_start
      t.date :period_end
      t.datetime :generated_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
      t.datetime :read_at
      t.datetime :dismissed_at
      # Embeds the insight type and subject, e.g. "spending_anomaly:<category-id>:2026-07",
      # so re-running the nightly job refreshes the existing row instead of duplicating it.
      t.string :dedup_key, null: false

      t.timestamps
    end

    add_check_constraint :insights, "priority IN ('high', 'medium', 'low')", name: "chk_insights_priority"
    add_check_constraint :insights, "status IN ('active', 'read', 'dismissed', 'expired')", name: "chk_insights_status"

    add_index :insights, [ :family_id, :status ]
    add_index :insights, [ :family_id, :dedup_key ], unique: true
    add_index :insights, [ :family_id, :generated_at ]
  end
end
