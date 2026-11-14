class CreateWeeklyCleanupRuns < ActiveRecord::Migration[8.1]
  def change
    create_table :weekly_cleanup_runs, id: :uuid do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid
      t.references :user, null: false, foreign_key: true, type: :uuid
      t.date :period_start, null: false
      t.jsonb :summary, default: {}, null: false
      t.timestamps

      t.index [ :family_id, :user_id, :period_start ], unique: true, name: "idx_weekly_cleanup_runs_dedup"
    end
  end
end
