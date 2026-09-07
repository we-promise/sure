class AddReplayRequestedAtToPlaidItems < ActiveRecord::Migration[7.2]
  def change
    add_column :plaid_items, :replay_requested_at, :datetime
  end
end
