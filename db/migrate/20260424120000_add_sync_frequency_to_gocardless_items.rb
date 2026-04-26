class AddSyncFrequencyToGocardlessItems < ActiveRecord::Migration[7.2]
  def change
    add_column :gocardless_items, :sync_frequency, :string, default: "manual", null: false, if_not_exists: true
  end
end
