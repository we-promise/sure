class CreateInsights < ActiveRecord::Migration[7.2]
  def change
    create_table :insights, id: :uuid do |t|
      t.references :family, null: false, type: :uuid, foreign_key: { on_delete: :cascade }
      t.string  :insight_type, null: false
      t.string  :priority,     null: false, default: "medium"
      t.string  :status,       null: false, default: "active"
      t.string  :title,        null: false
      t.text    :body,         null: false
      t.jsonb   :metadata,     null: false, default: {}
      t.string  :currency,     null: false, default: "USD"
      t.date    :period_start
      t.date    :period_end
      t.datetime :generated_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
      t.datetime :read_at
      t.datetime :dismissed_at
      t.string  :dedup_key,    null: false

      t.timestamps
    end

    add_index :insights, [ :family_id, :status ]
    add_index :insights, [ :family_id, :insight_type, :dedup_key ], unique: true, name: "index_insights_on_family_type_dedup_key"
    add_index :insights, [ :family_id, :generated_at ]

    add_check_constraint :insights, "priority IN ('high', 'medium', 'low')", name: "chk_insights_priority"
    add_check_constraint :insights, "status IN ('active', 'read', 'dismissed')", name: "chk_insights_status"
  end
end
