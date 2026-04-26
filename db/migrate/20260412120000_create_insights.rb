class CreateInsights < ActiveRecord::Migration[7.2]
  def change
    create_table :insights, id: :uuid do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid

      t.string :insight_type, null: false
      t.string :priority,     null: false, default: "medium"
      t.string :status,       null: false, default: "active"

      t.string :title,        null: false
      t.text   :body,         null: false
      t.jsonb  :metadata,     null: false, default: {}
      t.string :currency,     null: false, default: "USD"

      t.date     :period_start
      t.date     :period_end
      t.datetime :generated_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
      t.datetime :read_at
      t.datetime :dismissed_at

      # Prevents re-inserting the same insight type for the same period;
      # also used to detect whether numbers changed enough to reactivate a dismissed insight.
      t.string :dedup_key, null: false

      t.timestamps
    end

    add_index :insights, [ :family_id, :status ]
    add_index :insights, [ :family_id, :generated_at ]
    add_index :insights, [ :family_id, :dedup_key ], unique: true
  end
end
