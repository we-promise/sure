class CreateSyncSchedules < ActiveRecord::Migration[8.1]
  def change
    create_table :sync_schedules, id: :uuid do |t|
      t.references :syncable, polymorphic: true, type: :uuid, null: false, index: { unique: true }
      t.integer :interval_minutes, null: false
      t.datetime :next_run_at, null: false

      t.timestamps
    end

    add_index :sync_schedules, :next_run_at
  end
end
