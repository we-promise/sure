class AddScheduleToRules < ActiveRecord::Migration[7.2]
  def change
    add_column :rules, :schedule_cron, :string
    add_column :rules, :schedule_enabled, :boolean, default: false, null: false
  end
end
